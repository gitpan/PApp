#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdio.h> /*D*/

#define is_dbh(sv) (sv && SvROK (sv) && sv_derived_from (sv, "DBI::db"))

typedef struct lru_node {
  struct lru_node *next;
  struct lru_node *prev;
  U32 hash; /* we do not really do any hashing, yet */
  SV *dbh;
  SV *sql;

  SV *sth;
#if 0 /* method cache */
  GV *execute;
  GV *bind_columns;
  GV *fetch;
#endif
} lru_node;

static lru_node lru_list;
static int lru_size    =  0;
static int lru_maxsize = 50;

#define lru_init lru_list.next = &lru_list; lru_list.prev = &lru_list /* other fields are zero */

/* this is primitive, yet effective */
/* the returned value must never be zero (or bad things will happen) */
#define lru_hash do {	\
	hash = (((U32)dbh)>>2);	\
        hash += *statement;\
        hash += len;		\
} while (0)

/* fetch and "use" */
/* could be done using a single call (we could call prepare!) */
static SV *lru_fetch(SV *dbh, SV *sql)
{
  lru_node *n;

  U32 hash;
  STRLEN len;
  char *statement = SvPV (sql, len);

  dbh = SvRV (dbh);

  lru_hash;

  /*fprintf (stderr, "F: %08lx %s\n", hash, SvPV_nolen (sql));/*D*/

  n = &lru_list;
  do {
    n = n->next;
    if (!n->hash)
      return 0;
  } while (n->hash != hash
           || !sv_eq (n->sql, sql)
           || n->dbh != dbh);

  /* found, so return to the start of the list */
  n->prev->next = n->next;
  n->next->prev = n->prev;

  n->next = lru_list.next;
  n->prev = &lru_list;
  lru_list.next->prev = n;
  lru_list.next = n;

  return n->sth;
}

static void lru_nukeone(void)
{
  lru_node *n;
  /* nuke at the end */

  n = lru_list.prev;

  lru_list.prev = n->prev;
  n->prev->next = &lru_list;

  /*fprintf (stderr, "N: %s\n", SvPV_nolen (n->sql));/*D*/

  SvREFCNT_dec (n->dbh);
  SvREFCNT_dec (n->sql);
  SvREFCNT_dec (n->sth);
  Safefree (n);
  
  lru_size--;
}

/* store a not-yet existing entry(!) */
static void lru_store(SV *dbh, SV *sql, SV *sth)
{
  lru_node *n;

  U32 hash;
  STRLEN len;
  char *statement = SvPV (sql, len);

  dbh = SvRV (dbh);

  lru_hash;

  /*fprintf (stderr, "S: %08lx %s\n", hash, SvPV_nolen (sql));/*D*/

  lru_size++;
  if (lru_size > lru_maxsize)
    lru_nukeone ();

  New (0, n, 1, lru_node);

  n->hash = hash;
  n->dbh = dbh; SvREFCNT_inc (dbh); /* note: this is the dbi hash itself, not the reference */
  n->sql = newSVsv (sql);
  n->sth = sth; SvREFCNT_inc (sth);

  n->next = lru_list.next;
  n->prev = &lru_list;
  lru_list.next->prev = n;
  lru_list.next = n;
}

static GV *sql_exec;
static GV *DBH;

MODULE = PApp::SQL		PACKAGE = PApp::SQL

PROTOTYPES: DISABLE

BOOT:
   lru_init;
   sql_exec = gv_fetchpv ("sql_exec", TRUE, SVt_PV);
   DBH      = gv_fetchpv ("DBH"     , TRUE, SVt_PV);

int
cachesize(size = -1)
	int	size
	CODE:
        RETVAL = lru_maxsize;
        if (size >= 0)
          {
            lru_maxsize = size;
            while (lru_size > lru_maxsize)
              lru_nukeone ();
          }

        OUTPUT:
        RETVAL

void
sql_exec(...)
	ALIAS:
        	sql_fetch    = 1
                sql_fetchall = 2
	PPCODE:
{
	if (items == 0)
          croak ("Usage: sql_exec [database-handle,] [bind-var-refs,... ] \"sql-statement\", [arguments, ...]");
        else
          {
            int arg = 0;
            int bind_first, bind_last;
            int count;
            SV *dbh = ST(0);
            SV *sth;
            SV *sql;
            SV *execute;

            /* save our arguments against destruction through function calls */
            SP += items;
            
            /* first check wether we should use an explicit db handle */
            if (!is_dbh (dbh))
              {
                dbh = get_sv ("DBH", FALSE);
                if (!is_dbh (dbh))
                  {
                    dbh = GvSV(DBH);
                    if (!is_dbh (dbh))
                      croak ("sql_exec: no $DBH found in current package or in PApp::SQL::");
                  }
              }
            else
              arg++; /* we consumed one argument */

            /* count the remaining references (for bind_columns) */
            bind_first = arg;
            while (items > arg && SvROK (ST(arg)))
              arg++;

            bind_last = arg;

            /* consume the sql-statement itself */
            if (items <= arg)
              croak ("sql_exec: required argument \"sql-statement\" missing");

            if (!SvPOK (ST(arg)))
              croak ("sql_exec: sql-statement must be a string");

            sql = ST(arg); arg++;

            /* check cache for existing statement handle (NYI) */
            sth = lru_fetch (dbh, sql);
            if (!sth)
              {
                PUSHMARK (SP);
                EXTEND (SP, 2);
                PUSHs (dbh);
                PUSHs (sql);
                PUTBACK;
                count = call_method ("prepare", G_SCALAR);
                SPAGAIN;

                if (count != 1)
                  croak ("sql_exec: unable to prepare() statement '%s': %s",
                         SvPV_nolen (sql),
                         SvPV_nolen (get_sv ("DBI::errstr", TRUE)));

                sth = POPs;

                lru_store (dbh, sql, sth);
              }

            PUSHMARK (SP);
            EXTEND (SP, items - arg + 1);
            PUSHs (sth);
            while (items > arg)
              {
                PUSHs (ST(arg));
                arg++;
              }

            PUTBACK;
            /* { static GV *execute;
              if (!execute) execute = gv_fetchmethod_autoload(SvSTASH(SvRV(sth)), "execute", 0);
              count = call_sv(GvCV(execute), G_SCALAR);
             }*/
            count = call_method ("execute", G_SCALAR);
            SPAGAIN;

            if (count != 1)
              croak ("sql_exec: execute() didn't return any value ('%s'): %s",
                     SvPV_nolen (sql),
                     SvPV_nolen (get_sv ("DBI::errstr", TRUE)));

            execute = POPs;

            if (!SvTRUE (execute))
              croak ("sql_exec: unable to execute statement '%s' (%s)",
                     SvPV_nolen (sql),
                     SvPV_nolen (get_sv ("DBI::errstr", TRUE)));

            sv_setsv (GvSV(sql_exec), execute);

            if (bind_first != bind_last)
              {
                PUSHMARK (SP);
                EXTEND (SP, bind_last - bind_first + 2);
                PUSHs (sth);
                do {
                  PUSHs (ST(bind_first));
                  bind_first++;
                } while (bind_first != bind_last);

                PUTBACK;
                count = call_method ("bind_columns", G_SCALAR);
                SPAGAIN;

                if (count != 1)
                  croak ("sql_exec: bind_columns() didn't return any value ('%s'): %s",
                         SvPV_nolen (sql),
                         SvPV_nolen (get_sv ("DBI::errstr", TRUE)));

                if (!SvOK (POPs))
                  croak ("sql_exec: bind_columns() didn't return a true ('%s'): %s",
                         SvPV_nolen (sql),
                         SvPV_nolen (get_sv ("DBI::errstr", TRUE)));
              }

            /* free our arguments from the stack */
            SP -= items;

            if (ix == 1)
              { /* sql_fetch */
                SV *row;

                PUSHMARK (SP);
                XPUSHs (sth);
                PUTBACK;
                count = call_method ("fetchrow_arrayref", G_SCALAR);
                SPAGAIN;

                if (count != 1)
                  abort ();

                row = POPs;

                if (SvROK (row))
                  {
                    AV *av;

                    switch (GIMME_V)
                      {
                        case G_VOID:
                          /* no thing */
                          break;
                        case G_SCALAR:
                          /* the first element */
                          XPUSHs (*av_fetch ((AV *)SvRV (row), 0, 1));
                          break;
                        case G_ARRAY:
                          av = (AV *)SvRV (row);
                          count = AvFILL (av) + 1;
                          EXTEND (SP, count);
                          for (arg = 0; arg < count; arg++)
                            PUSHs (AvARRAY (av)[arg]);

                          break;
                        default:
                          abort ();
                      }
                 }
              }
            else if (ix == 2)
              { /* sql_fetchall */
                SV *rows;

                PUSHMARK (SP);
                XPUSHs (sth);
                PUTBACK;
                count = call_method ("fetchall_arrayref", G_SCALAR);
                SPAGAIN;

                if (count != 1)
                  abort ();

                rows = POPs;

                if (SvROK (rows))
                  {
                    AV *av = (AV *)SvRV (rows);
                    count = AvFILL (av) + 1;

                    if (count)
                      {
                        int columns = AvFILL ((AV *)SvRV (AvARRAY(av)[0])) + 1; /* columns? */

                        EXTEND (SP, count);
                        if (columns == 1)
                          for (arg = 0; arg < count; arg++)
                            PUSHs (AvARRAY ((AV *)SvRV (AvARRAY (av)[arg]))[0]);
                        else
                          for (arg = 0; arg < count; arg++)
                            PUSHs (AvARRAY (av)[arg]);
                      }
                 }
              }
            else
              XPUSHs (sth);

          }
}



