#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if _POSIX_SOURCE
#include <unistd.h>
#endif
#include <string.h>

/* agni */

#define CACHEp "_cache"
#define CACHEl (sizeof (CACHEp) - 1)
#define TYPEp  "_type"
#define TYPEl  (sizeof (TYPEp) - 1)

static U32 CACHEh, TYPEh;
static MGVTBL vtbl_agni_object = {0, 0, 0, 0, 0};

static U32
compute_hash (char *key, I32 len)
{
  U32 hash;

  PERL_HASH (hash, key, len);

  return hash;
}

/* freeze, and store */
static void
freeze_store (SV *self, SV *obj, SV *value)
{
  dSP;
  SV *saveerr = SvOK (ERRSV) ? sv_mortalcopy (ERRSV) : 0; /* this is necessary because we can't use KEEPERR, or can we? */
  SV *data;
  int c;

  PUSHMARK (SP); EXTEND (SP, 3); PUSHs (self); PUSHs (value); PUSHs (obj); PUTBACK;
  c = call_method ("freeze", G_SCALAR | G_EVAL);
  SPAGAIN;

  if (SvTRUE (ERRSV))
    croak (0);

  if (c == 1)
    data = POPs;
  else if (c == 0)
    data = &PL_sv_undef;
  else
    croak ("TYPE->freeze must return at most one return value");

  PUSHMARK (SP); EXTEND (SP, 3); PUSHs (self); PUSHs (obj); PUSHs (data); PUTBACK;
  call_method ("store", G_VOID | G_DISCARD | G_EVAL);
  SPAGAIN;

  if (SvTRUE (ERRSV))
    croak (0);

  if (saveerr)
    sv_setsv (ERRSV, saveerr);

  PUTBACK;
}

static SV *obj_by_gid (SV *obj, SV *gid)
{
  dSP;
  SV **path =hv_fetch ((HV *)SvRV (obj), "_path", 5, 0);

  if (path && *path)
    {
      PUSHMARK (SP); EXTEND (SP, 2); PUSHs (*path); PUSHs (gid);
      PUTBACK;
      if (call_pv ("Agni::path_obj_by_gid", G_SCALAR | G_EVAL) == 1)
        {
          SPAGAIN;
          return POPs;
        }
    }

  return 0;
}

/* fetch, and thaw, and push ;) */
static void
fetch_thaw_push (SV *self, SV *obj)
{
  dSP;
  SV *saveerr = SvOK (ERRSV) ? sv_mortalcopy (ERRSV) : 0; /* this is necessary because we can't use KEEPERR, or can we? */
  SV *save_mh = HeVAL (&PL_hv_fetch_ent_mh); /* perl bug, FETCH recursively clobbers PL_hv..mh */
  SV *data;
  int c;

  /* $self->fetch($obj) */
  PUSHMARK (SP); EXTEND(SP, 2); PUSHs (self); PUSHs (obj); PUTBACK;
  c = call_method ("fetch", G_SCALAR | G_EVAL);
  SPAGAIN;

  if (SvTRUE (ERRSV))
    croak (0);

  if (c == 1)
    data = POPs;
  else if (c == 0)
    data = &PL_sv_undef;
  else
    croak ("TYPE->fetch must return at most one return value");

  /* $self->thaw($data) */
  PUSHMARK (SP); EXTEND (SP, 3); PUSHs (self); PUSHs (data); PUSHs (obj); PUTBACK;
  c = call_method ("thaw", G_SCALAR | G_EVAL);
  SPAGAIN;

  if (SvTRUE (ERRSV))
    croak (0);

  if (c == 1)
    XPUSHs (POPs);
  else if (c == 0)
    ; /*NOP*/
  else
    croak ("TYPE->thaw must return at most one return value");

  HeVAL (&PL_hv_fetch_ent_mh) = save_mh;

  if (saveerr)
    sv_setsv (ERRSV, saveerr);

  PUTBACK;
}

/* papp */

/*
 * return wether the given sv really is a "scalar value" (i.e. something
 * we can cann setsv on without getting a headache.
 */
#define sv_is_scalar_type(sv)	\
	(SvTYPE (sv) != SVt_PVAV \
	&& SvTYPE (sv) != SVt_PVHV \
	&& SvTYPE (sv) != SVt_PVCV \
	&& SvTYPE (sv) != SVt_PVIO)

/*****************************************************************************/

/*
 * the expectation that perl strings have an appended zero is spread all over this file, yet
 * it breaks it itself almost everywhere.
 */

typedef unsigned char uchar;

static uchar e64[ 64] = "0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ.abcdefghijklmnopqrstuvwxyz";
static uchar d64[256];

#define x64_enclen(len) (((len) * 4 + 2) / 3)

#define INT_ERR(s) croak ("internal error " s)

static void
x64_enc (uchar *dst, uchar *src, STRLEN len)
{
  while (len >= 3)
    {
      *dst++ = e64[                          src[0] & 0x3f ];
      *dst++ = e64[((src[0] & 0xc0) >> 2) | (src[1] & 0x0f)];
      *dst++ = e64[((src[1] & 0xf0) >> 2) | (src[2] & 0x03)];
      *dst++ = e64[((src[2] & 0xfc) >> 2)                  ];
      src += 3; len -= 3;
    }

  switch (len)
    {
      case 2:
        *dst++ = e64[                          src[0] & 0x3f ];
        *dst++ = e64[((src[0] & 0xc0) >> 2) | (src[1] & 0x0f)];
        *dst++ = e64[((src[1] & 0xf0) >> 2)                  ];
        break;
      case 1:
        *dst++ = e64[                          src[0] & 0x3f ];
        *dst++ = e64[((src[0] & 0xc0) >> 2)                  ];
        break;
      case 0:
        break;
    }
}

static I32
papp_filter_read(pTHX_ int idx, SV *buf_sv, int maxlen)
{
  dSP;
  SV *datasv = FILTER_DATA (idx);

  ENTER;
  SAVETMPS;
  PUSHMARK (SP);
  XPUSHs (sv_2mortal (newSViv (idx)));
  XPUSHs (buf_sv);
  XPUSHs (sv_2mortal (newSViv (maxlen)));
  PUTBACK;
  maxlen = call_sv ((SV* )IoBOTTOM_GV (datasv), G_SCALAR);
  SPAGAIN;

  if (maxlen != 1)
    croak ("papp_filter_read: filter read function must return a single integer");

  maxlen = POPi;
  FREETMPS;
  LEAVE;

  if (maxlen <= 0)
    {
      SvREFCNT_dec (IoBOTTOM_GV (datasv));
      filter_del (papp_filter_read);
    }

  return maxlen;
}

/*****************************************************************************/

/* cache these gv's for quick access */
static GV *cipher_e,
          *pmod,
          *curpath,
          *curprfx,
          *location,
          *module,
          *modules,
          *userid,
          *stateid,
          *sessionid,
          *state,
          *arguments,
          *surlstyle,
          *big_a,
          *big_s,
          *big_p;
          
static void
append_modpath(SV *r, HV *hv)
{
  SV **module = hv_fetch (hv, "\x00", 1, 0);

  if (module)
    sv_catsv (r, *module);

  if (hv_iterinit (hv) > 0)
    {
      HE *he;

      while ((he = hv_iternext (hv)))
        {
          I32 len;
          char *key;
          SV *val;

          key = hv_iterkey (he, &len);

          if (len == 1 && !*key)
            continue;

          val = hv_iterval (hv, he);

          if (!SvROK (val) || SvTYPE (SvRV (val)) != SVt_PVHV)
            croak ("modpath_freeze: hashref expected (1)");

          val = SvRV (val);

          if (!HvKEYS ((HV *)val))
            continue;

          sv_catpvn (r, "+", 1);
          sv_catpvn (r, key, len);
          sv_catpvn (r, "=", 1);
          append_modpath (r, (HV *)val);
        }
    }
    sv_catpvn (r, "-", 1);
}

static SV *
modpath_freeze (SV *modules)
{
  SV *r = newSVpvn ("", 0);

  if (!SvROK (modules) || SvTYPE (SvRV (modules)) != SVt_PVHV)
    croak ("modpath_freeze: hashref expected (0)");

  append_modpath (r, (HV *)SvRV (modules));

  do {
    SvCUR_set (r, SvCUR (r) - 1); /* chop final '-' */
  } while (SvEND (r)[-1] == '-');

  return r;
}

static HV *
modpath_thaw (char **srcp, char *end)
{
  HV *hv = newHV ();
  char *src = *srcp;

  if (src < end)
    {
      char *path;
      
      path = src;
      while (src < end && *src != '=' && *src != '-' && *src != '+' && *src != '/')
        src++;

      if (src - path) /* do not store "empty" paths */
        if (!hv_store (hv, "\x00", 1, newSVpvn (path, src - path), 0))
          INT_ERR ("insert_modpath_1");

      while (src < end && *src == '+')
        {
          char *module;
          HV *hash;

          src++;

          module = src;
          while (src < end && *src != '=' && *src != '-' && *src != '+' && *src != '/')
            src++;

          if (*src != '=')
            croak ("malformed module path (=)");

          *srcp = src + 1;
          hash = modpath_thaw (srcp, end);

          if (HvKEYS (hash)) /* optimization, do not store empty components */
            if (!hv_store (hv, module, src - module, newRV_noinc ((SV *)hash), 0))
              INT_ERR ("insert_modpath_2");

          src = *srcp;
        }

      if (src < end && *src++ != '-')
        croak ("malformed module path (-)");
    }

  *srcp = src;

  return hv;
}

/* for the given path, find the corresponding hash and element name */
static char *
find_path (SV *path, HV **hashp)
{
  char *str = SvPV_nolen (path);
  char *elem = strrchr (str, '/');
  HV *hash;

  if (!elem)
    croak ("non-absolute element path (%s) not supported by find_path", str);

  if (*str == '-')
    {
      hash = GvHV (arguments);
      str++;
    }
  else
    hash = GvHV (state);

  /* unless root module (this is unclean) */
  if (elem != str)
    {
      SV **modhash = hv_fetch (hash, str, elem - str, 1);

      /* create it if necessary */
      if (!SvROK (*modhash) || SvTYPE (SvRV (*modhash)) != SVt_PVHV)
        sv_setsv (*modhash, newRV_noinc ((SV *)newHV ()));

      hash = (HV *)SvRV (*modhash);
    }

  *hashp = hash;
  return elem + 1;
}

#define SURL_SUFFIX	0x41
#define SURL_STYLE	0x42

#define SURL_EXEC_IMMED	0x91

#define SURL_PUSH	0x01
#define SURL_POP	0x81
#define SURL_UNSHIFT	0x02
#define SURL_SHIFT	0x82

static AV *
rv2av(SV *sv)
{
  AV *av;

  if (!sv)
    return 0;
  else if (SvROK (sv))
    av = (AV *)SvRV (sv);
  else if (SvOK (sv))
    av = 0;
  else
    {
      SV *rv;
      av = newAV ();
      rv = newRV_noinc ((SV *)av);
      sv_setsv_mg (sv, rv);
      SvREFCNT_dec (rv);
    }

  if (!av || SvTYPE ((SV *)av) != SVt_PVAV)
    croak ("attempted surl push/unshift to a non-array-reference");

  return av;
}

static SV *
find_keysv (SV *arg, int may_delete)
{
  SV *sv;
  HV *hash;
  char *elem;

  if (SvROK (arg))
    {
      sv = SvRV (arg);
      if (!sv_is_scalar_type (sv))
        croak ("find_keysv: tried to assign scalar to non-scalar reference (2)");
    }
  else if (may_delete && 0) /* optimization removed for agni */
    {
      elem = find_path (arg, &hash);
      /* setting an element to undef may delete it */
      hv_delete (hash, elem, SvEND (arg) - elem, G_DISCARD);
      sv = 0;
    }
  else
    {
      elem = find_path (arg, &hash);
      sv = *hv_fetch (hash, elem, SvEND (arg) - elem, 1);
    }

  return sv;
}

/* do path resolution. not much yet. */
static SV *
expand_path(char *path, STRLEN pathlen, char *cwd, STRLEN cwdlen)
{
  SV *res = newSV (0);

  if (*path == '-')
    {
      sv_catpvn (res, path, 1);
      path++; pathlen--;
    }

  if (*path != '/')
    {
      sv_catpvn (res, cwd, cwdlen ? cwdlen : strlen (cwd));

      if (SvEND(res)[-1] != '/')
        sv_catpvn (res, "/", 1);
    }

  sv_catpvn (res, path, pathlen);

  return res;
}
          
static SV *
eval_path_ (char *path, char *end)
{
  SV *pathinfo;

  if (path > end)
    {
      pathinfo = modpath_freeze (GvSV (modules));
    }
  else
    {
      SV *modpath;
      SV **ent;
      SV *dest;
      STRLEN cwdlen;
      char *cwd = SvPV (GvSV (curpath), cwdlen);
      char *pend = path;

      while (pend < end && *pend != ',')
        pend++;

      dest = expand_path (path, pend - path, cwd, cwdlen);

      pend++; /* skip trailing ",", if any */

      cwd = SvPV (dest, cwdlen);
      modpath = GvSV (modules);

      for(;;) {
        path = cwd + 1;
        cwd = strchr (path, '/');

        if (!cwd)
          break;

        ent = hv_fetch ((HV *)SvRV (modpath), path, cwd ? cwd - path : 0, 1);

        if (!ent)
          INT_ERR("eval_path_1");

        if (!SvROK (*ent))
          sv_setsv (*ent, newRV_noinc ((SV *)newHV ()));

        modpath = *ent;
      };

      sv_chop (dest, path); /* get the last component of dest as sv */

      if (SvCUR (dest) == 1 && *path == '.')
        pathinfo = eval_path_ (pend, end); /* module "." == noop */
      else
        {
          modpath = SvRV (modpath);
          ent = hv_fetch ((HV *)modpath, "\x00", 1, 0);

          if (!ent)
            {
              if (SvCUR (dest))
                if (!hv_store ((HV *)modpath, "\x00", 1, SvREFCNT_inc (dest), 0))
                  INT_ERR ("surl_1");

              pathinfo = eval_path_ (pend, end);

              hv_delete ((HV *)modpath, "\x00", 1, G_DISCARD);
            }
          else
            {
              /* should unify this with previous case by removing/inserting weverytime */
              /* and optimizing as we go */
              SV *old_modpath = *ent;

              /* just a new module */
              *ent = dest;

              pathinfo = eval_path_ (pend, end);

              *ent = old_modpath;
            }
        }

      SvREFCNT_dec (dest);
    }

  return pathinfo;
}

static SV *
eval_path (SV *path)
{
  STRLEN len;
  char *pth = SvPV(path, len);
  
  if (!SvROK (GvSV (modules)))
    croak ("$PApp::modules not set");
  if (!SvPOK (GvSV (curpath)))
    croak ("$PApp::curpath not set");

  return eval_path_ (pth, pth + len);
}

/* checks wether this surl argument is a single arg (1) or key->value (0) */
/* should be completely pluggable, i.e. by subclassing/calling PApp::SURL->gen */
#define SURL_NOARG(sv) (SvROK (sv) && sv_isa (sv, "PApp::Callback::Function"))

/*****************************************************************************/

MODULE = PApp		PACKAGE = PApp

BOOT:
{
  cipher_e     = gv_fetchpv ("PApp::cipher_e"    , TRUE, SVt_PV);
  pmod         = gv_fetchpv ("PApp::pmod"        , TRUE, SVt_PV);
  curpath      = gv_fetchpv ("PApp::curpath"     , TRUE, SVt_PV);
  curprfx      = gv_fetchpv ("PApp::curprfx"     , TRUE, SVt_PV);
  location     = gv_fetchpv ("PApp::location"    , TRUE, SVt_PV);
  big_a        = gv_fetchpv ("PApp::A"           , TRUE, SVt_PV);
  big_p        = gv_fetchpv ("PApp::P"           , TRUE, SVt_PV);
  big_s        = gv_fetchpv ("PApp::S"           , TRUE, SVt_PV);
  state        = gv_fetchpv ("PApp::state"       , TRUE, SVt_PV);
  arguments    = gv_fetchpv ("PApp::arguments"   , TRUE, SVt_PV);
  userid       = gv_fetchpv ("PApp::userid"      , TRUE, SVt_IV);
  stateid      = gv_fetchpv ("PApp::stateid"     , TRUE, SVt_IV);
  sessionid    = gv_fetchpv ("PApp::sessionid"   , TRUE, SVt_IV);
  module       = gv_fetchpv ("PApp::module"      , TRUE, SVt_PV);
  modules      = gv_fetchpv ("PApp::modules"     , TRUE, SVt_PV);
  surlstyle    = gv_fetchpv ("PApp::surlstyle"   , TRUE, SVt_IV);
}

# the most complex piece of shit
void
surl(...)
	PROTOTYPE: @
        ALIAS:
           salternative = 1
	PPCODE:
{
        int i;
        int has_module; /* wether a module has been given or not */
        UV xalternative;
        SV *surl;
        AV *args = newAV ();
        SV *pathinfo;
        SV *dstmodule;
        SV *path = 0;
        char *xcurprfx;
        STRLEN lcurprfx;
        char *svp; STRLEN svl;
        int style = 1;

        if (!SvPOK (GvSV (curprfx)))
          croak ("$PApp::curprfx not set");

        if (SvIOK (GvSV (surlstyle)))
          style = SvIV (GvSV (surlstyle));

        {
          int j;

          has_module = items;
          for (j = 0; j < items; j++)
            if (SURL_NOARG (ST(j)))
              has_module++;

          has_module &= 1;
        }

        if (has_module)
          {
            dstmodule = ST(0);
            i = 1;
          }
        else
          {
            dstmodule = GvSV (module);
            i = 0;
          }

        if (SvROK (dstmodule))
          {
            if (SvTYPE (SvRV (dstmodule)) != SVt_PV)
              croak ("surl: destination module must be either scalar or ref to scalar");

            pathinfo = newSVsv (SvRV (dstmodule));
          }
        else
          pathinfo = eval_path (dstmodule);

        xcurprfx = SvPV (GvSV (curprfx), lcurprfx);

        if (!ix || has_module) /* only set module when explicitly given */
          av_push (args, SvREFCNT_inc (pathinfo));

        for (; i < items; i++)
          {
            SV *arg = ST(i);

            if (SURL_NOARG (arg))
              {
                /* SURL_EXEC() */
                av_push (args, newSVpvn ("\x00\x01", 2));
                av_push (args, NEWSV (0,0));
                av_push (args, newSVpv ("/papp_execonce", 0));
                av_push (args, SvREFCNT_inc (arg));
              }
            else
              {
                SV *val = ST(i+1);
                i++;

                if (SvROK (arg))
                  {
                    if (!sv_is_scalar_type (SvRV (arg)))
                      croak ("surl: tried to assign scalar to non-scalar reference (e.g. 'surl \\@x => 5')");

                    arg = newSVsv (arg);
                    val = newSVsv (val);
                  }
                else if (SvPOK(arg) && SvCUR (arg) == 2 && !*SvPV_nolen (arg))
                  /* do not expand SURL_xxx constants */
                  {
                    int surlmod = (unsigned char)SvPV_nolen (arg)[1];

                    if (surlmod == SURL_STYLE)
                      {
                        style = SvIV (val);
                        continue;
                      }
                    else if (surlmod == SURL_SUFFIX)
                      {
                        path = val;
                        continue;
                      }
                    else if (surlmod == SURL_EXEC_IMMED)
                      {
                        if (!SvROK (val))
                          croak ("INTERNAL ERROR SURL_EXEC_IMMED");

                        val = newSVsv (SvRV (val));
                      }
                    else if ((surlmod == SURL_POP || surlmod == SURL_SHIFT)
                             && !SvROK (val))
                      {
                        svp = SvPV (val, svl);
                        val = expand_path (svp, svl, xcurprfx, lcurprfx);
                      }
                    else
                      {
                        val = newSVsv (val);
                      }

                    SvREFCNT_inc (arg);
                  }
                else
                  {
                    svp = SvPV (arg, svl);
                    arg = expand_path (svp, svl, xcurprfx, lcurprfx);
                    val = newSVsv (val);
                  }

                av_push (args, arg);
                av_push (args, val);
              }
          }

        if (ix == 1)
          {
            /* salternative */
            XPUSHs (sv_2mortal (newRV_noinc ((SV *) args)));
          }
        else
          {
            surl = sv_mortalcopy (GvSV (location));
            sv_catpvn (surl, "/", 1);
            sv_catsv (surl, pathinfo);

            if (style == 3 && GIMME_V != G_ARRAY)
              {
                SvREFCNT_dec (args);
                XPUSHs (surl);
              }
            else
              {
                AV *av;
                SV **he = hv_fetch ((HV *)GvHV (state), "papp_alternative", 16, 0);

                if (!he || !SvROK ((SV *)*he))
                  croak ("$state{papp_alternative} not an arrayref");

                av = (AV *)SvRV ((SV *)*he);
                av_push (av, newRV_noinc ((SV *) args));
                xalternative = av_len (av);

                if (GIMME_V != G_VOID)
                  {
                    uchar key[x64_enclen (16)];
                    int count;
                    UV xuserid    = SvUV (GvSV (userid));
                    UV xstateid   = SvUV (GvSV (stateid));
                    UV xsessionid = SvUV (GvSV (sessionid));

                    key[ 0] = xuserid     ; key[ 1] = xuserid      >> 8; key[ 2] = xuserid      >> 16; key[ 3] = xuserid      >> 24;
                    key[ 4] = xstateid    ; key[ 5] = xstateid     >> 8; key[ 6] = xstateid     >> 16; key[ 7] = xstateid     >> 24;
                    key[ 8] = xalternative; key[ 9] = xalternative >> 8; key[10] = xalternative >> 16; key[11] = xalternative >> 24;
                    key[12] = xsessionid  ; key[13] = xsessionid   >> 8; key[14] = xsessionid   >> 16; key[15] = xsessionid   >> 24;

                    ENTER;
                    PUSHMARK (SP);
                    XPUSHs (GvSV (cipher_e));
                    XPUSHs (sv_2mortal (newSVpvn ((char *)key, 16)));
                    PUTBACK;
                    count = call_method ("encrypt", G_SCALAR);
                    SPAGAIN;

                    assert (count == 1);

                    x64_enc (key, POPp, 16);

                    LEAVE;

                    if (style == 1) /* url */
                      {
                        sv_catpvn (surl, "/", 1);
                        sv_catpvn (surl, key, x64_enclen (16));
                      }
                    else if (style == 2) /* get */
                      {
                        if (path)
                          {
                            sv_catpvn (surl, "/", 1);
                            sv_catsv (surl, path);
                          }

                        sv_catpvn (surl, "?papp=", 6);
                        sv_catpvn (surl, key, x64_enclen (16));
                      }
                    else if (style == 3) /* empty */
                      ;
                    else
                      croak ("illegal surlstyle %d requested", style);

                    XPUSHs (surl);
                    if (style == 3 && GIMME_V == G_ARRAY)
                      XPUSHs (sv_2mortal (newSVpvn (key, x64_enclen (16))));
                  }
              }
          }

        SvREFCNT_dec (pathinfo);
}

SV *
eval_path(path)
	SV *	path
	PROTOTYPE: $
        CODE:
        RETVAL = eval_path (path);
	OUTPUT:
        RETVAL

SV *
expand_path(path, cwd)
	SV	*path
        SV	*cwd
        PROTOTYPE: $$
        CODE:
        STRLEN cwdlen;
        char *cwdp = SvPV (cwd, cwdlen);
        STRLEN pathlen;
        char *pathp = SvPV (path, pathlen);

        RETVAL = expand_path (pathp, pathlen, cwdp, cwdlen);
	OUTPUT:
	RETVAL

# interpret argument => value pairs
void
set_alternative(array)
	SV *	array
        PROTOTYPE: $
        CODE:

        if (!SvROK (array) || SvTYPE (SvRV (array)) != SVt_PVAV)
          croak ("arrayref expected as argument to set_alternative");
        else
          {
            AV *av = (AV *)SvRV (array);
            int len = av_len (av);
            int flags = 0, i = 0;

            if (~len & 1) /* odd array length? */
              {
                SV * modulepath = *av_fetch (av, i++, 1);
                STRLEN len;
                char *src = SvPV (modulepath, len);

                sv_setsv (GvSV (modules), newRV_noinc ((SV *)modpath_thaw (&src, src + len)));
              }

            while (i < len)
              {
                SV *arg = *av_fetch (av, i++, 1);
                SV *val = *av_fetch (av, i++, 1);

                if (!SvROK (arg) && SvCUR (arg) == 2 && !*SvPV_nolen (arg))
                  {
                    /* SURL_xxx constant */
                    int surlmod = (unsigned char)SvPV_nolen (arg)[1];

                    if (surlmod & 0x80)
                      {
                        if (surlmod == SURL_POP || surlmod == SURL_SHIFT)
                          {
                            AV *av = rv2av (find_keysv (val, 0));

                            if (av && av_len (av) >= 0)
                              {
                                if (surlmod == SURL_POP)
                                  SvREFCNT_dec (av_pop (av));
                                else
                                  SvREFCNT_dec (av_shift (av));
                              }
                          }
                        else if (surlmod == SURL_EXEC_IMMED)
                          {
                            PUSHMARK (SP); PUTBACK;
                            call_sv (val, G_VOID | G_DISCARD);
                            SPAGAIN;
                          }
                        else
                          croak ("set_alternative: unsupported surlmod (%02x)", surlmod);
                      }
                    else
                      flags |= surlmod;
                  }
                else
                  {
                    SV *sv = find_keysv (arg, !flags && !SvOK (val));

                    if (sv)
                      {
                        int arrayop = flags & 3;

                        if (arrayop)
                          {
                            AV *av = rv2av (sv);

                            if (arrayop == SURL_PUSH)
                              av_push (av, SvREFCNT_inc (val));
                            else if (arrayop == SURL_UNSHIFT)
                              {
                                av_unshift (av, 1);
                                if (!av_store (av, 0, SvREFCNT_inc (val)))
                                  SvREFCNT_dec (val);
                              }
                            else
                              croak ("illegal arrayop in set_alternative");
                          }
                        else
                          sv_setsv_mg (sv, val);
                      }

                    flags = 0;
                  }
              }
          }

void
find_path (path)
  	SV *	path
        PROTOTYPE: $
        PPCODE:
        HV *hash;
        char *elem = find_path (path, &hash);

        EXTEND (SP, 2);
        PUSHs (sv_2mortal (newRV_inc ((SV *)hash)));
        PUSHs (sv_2mortal (newSVpv (elem, 0)));

SV *
modpath_freeze(modules)
	SV * modules
        PROTOTYPE: $
        CODE:
        RETVAL = modpath_freeze (modules);
	OUTPUT:
        RETVAL

SV *
modpath_thaw(modulepath)
	SV * modulepath
        PROTOTYPE: $
        CODE:
        char *src, *end;
        STRLEN dc;
        
        src = SvPV (modulepath, dc);
        end = src + dc;

        RETVAL = newRV_noinc ((SV *)modpath_thaw (&src, end));
	OUTPUT:
        RETVAL

# destroy %P, %S and %state, but do not call DESTROY
# TODO: why %P here and not in update_state?
void
_destroy_state()
	CODE:
        HV *hv = PL_defstash;
        PL_defstash = 0;
        hv_clear (GvHV (big_s));
        hv_clear (GvHV (state));
        PL_defstash = hv;
        hv_clear (GvHV (big_p));

void
_set_params(...)
        CODE:
        int i;
        HV *hv = GvHV (big_p);

        for (i = 1; i < items; i += 2)
          {
            STRLEN klen;
            char *key = SvPV (ST(i-1), klen);
            SV *val = SvREFCNT_inc (ST(i));
            SV **ent = hv_fetch (hv, key, klen, 0);

            if (ent)
              {
                if (SvROK (*ent))
                  av_push ((AV *)SvRV (*ent), val);
                else
                  {
                    AV *av = newAV ();

                    av_push (av, *ent);
                    av_push (av, val);

                    *ent =  newRV_noinc ((SV *)av);
                  }
              }
            else
              hv_store (hv, key, klen, val, 0);
          }

MODULE = PApp		PACKAGE = PApp::Util

void
_exit(code=0)
	int	code
        CODE:
#if _POSIX_SOURCE
        _exit (code);
#else
        exit (code);
#endif

char *
sv_peek(sv)
	SV *	sv
        PROTOTYPE: $
        CODE:
        RETVAL = sv_peek (sv);
	OUTPUT:
	RETVAL

void
sv_dump(sv)
	SV *	sv
        PROTOTYPE: $
        CODE:
        sv_dump (sv);

void
filter_add(cb)
	SV *	cb
        PROTOTYPE: $
        CODE:
        SV *datasv = NEWSV (0,0);

        SvUPGRADE (datasv, SVt_PVIO);
        IoBOTTOM_GV (datasv) = (GV *)newSVsv (cb);
        filter_add (papp_filter_read, datasv);

I32
filter_read(idx, sv, maxlen)
	int	idx
	SV *	sv
        int	maxlen
	CODE:
        RETVAL = FILTER_READ (idx, sv, maxlen);
        OUTPUT:
        RETVAL

MODULE = PApp		PACKAGE = PApp::X64

BOOT:
{
  unsigned char c;

  for (c = 0; c < 64; c++)
    d64[e64[c]] = c;
}

PROTOTYPES: ENABLE

SV *
enc(data)
	SV *	data
        CODE:
{
        STRLEN len;
        uchar *src = (uchar *) SvPV (data, len);
        uchar *dst;

        RETVAL = NEWSV (0, x64_enclen(len));
        SvPOK_only (RETVAL);
        SvCUR_set (RETVAL, x64_enclen(len));
        dst = (uchar *)SvPV_nolen (RETVAL);

        x64_enc (dst, src, len);
}
	OUTPUT:
        RETVAL

SV *
dec(data)
	SV *	data
        CODE:
{
        STRLEN len;
        uchar a, b, c, d;
        uchar *src = (uchar *) SvPV (data, len);
        uchar *dst;

        RETVAL = NEWSV (0, len * 3 / 4 + 5);
        SvPOK_only (RETVAL);
        SvCUR_set (RETVAL, len * 3 / 4);
        dst = (uchar *)SvPV_nolen (RETVAL);

        while (len >= 4)
          {
            a = d64[*src++];
            b = d64[*src++];
            c = d64[*src++];
            d = d64[*src++];

            *dst++ = ((b << 2) & 0xc0) | a;
            *dst++ = ((c << 2) & 0xf0) | (b & 0x0f);
            *dst++ = ((d << 2) & 0xfc) | (c & 0x03);

            len -= 4;
          }

        switch (len)
          {
            case 3:
              a = d64[*src++];
              b = d64[*src++];
              c = d64[*src++];

              *dst++ = ((b << 2) & 0xc0) | a;
              *dst++ = ((c << 2) & 0xf0) | (b & 0x0f);
              break;
            case 2:
              a = d64[*src++];
              b = d64[*src++];

              *dst++ = ((b << 2) & 0xc0) | a;
              break;
            case 1:
              croak ("x64-encoded string malformed");
              abort ();
            case 0:
              break;
          }
}
	OUTPUT:
        RETVAL

MODULE = PApp		PACKAGE = Agni

char *
not64(a)
	char *	a
        PROTOTYPE: $
        ALIAS:
           bit64    = 1
        CODE:
        unsigned long long a_, c_;
        char c[64];

        a_ = strtoull (a, 0, 0);

        c_ = ix == 0 ? ~a_
           : ix == 1 ? 1 << a_
           :           -1;

        sprintf (c, "%llu", c_);
        
        RETVAL = c;
        OUTPUT:
	RETVAL

char *
and64(a,b)
	char *	a
	char *	b
        PROTOTYPE: $$
        ALIAS:
           or64     = 1
           andnot64 = 2
        CODE:
        unsigned long long a_, b_, c_;
        char c[64];

        a_ = strtoull (a, 0, 0);
        b_ = strtoull (b, 0, 0);

        c_ = ix == 0 ? a_ & b_
           : ix == 1 ? a_ | b_
           : ix == 2 ? a_ & ~b_
           :           -1;

        sprintf (c, "%llu", c_);
        
        RETVAL = c;
        OUTPUT:
	RETVAL


char *
unpack64(v)
        char *v;
        PROTOTYPE: $
        ALIAS:
           unpack64_le = 1
           unpack64_be = 2
        CODE:
        char buf[64];
        char *p = v;
#if BYTEORDER == 0x4321 || BYTEORDER == 0x87654321
        if(ix == 1)
#else
        if(ix == 2)
#endif
        {
          char t;
          p = &buf[16];
          buf[16] = v[7];
          buf[17] = v[6];
          buf[18] = v[5];
          buf[19] = v[4];
          buf[20] = v[3];
          buf[21] = v[2];
          buf[22] = v[1];
          buf[23] = v[0];
        }
        sprintf(buf, "%llu", *((unsigned long long *) p));

        RETVAL = buf;
        OUTPUT:
        RETVAL

SV *
pack64(v)
        char *v;
        PROTOTYPE: $
        ALIAS:
           pack64_le = 1
           pack64_be = 2
        CODE:
        unsigned long long val;
        uchar buf[64];

        val = strtoull(v, 0, 0);
        switch(ix) {
          case 1:
#if BYTEORDER != 0x4321 && BYTEORDER != 0x87654321
          case 0:
#endif
             buf[0] = val      ;
             buf[1] = val >>  8;
             buf[2] = val >> 16;
             buf[3] = val >> 24;
             buf[4] = val >> 32;
             buf[5] = val >> 40;
             buf[6] = val >> 48;
             buf[7] = val >> 56;
             break;
          case 2:
#if BYTEORDER == 0x4321 || BYTEORDER == 0x87654321
          case 0:
#endif
             buf[0] = val >> 56;
             buf[1] = val >> 48;
             buf[2] = val >> 40;
             buf[3] = val >> 32;
             buf[4] = val >> 24;
             buf[5] = val >> 16;
             buf[6] = val >>  8;
             buf[7] = val      ;
             break;
        }
        
        RETVAL = newSVpvn(buf, 8);
        OUTPUT:
        RETVAL

        


        
BOOT:
	CACHEh = compute_hash (CACHEp, CACHEl);
	TYPEh  = compute_hash (TYPEp,  TYPEl);

SV *
agnibless(SV *rv, char *classname)
        CODE:
        HV *hv = (HV *)SvRV (rv);

        sv_unmagic (rv, PERL_MAGIC_tied);

        RETVAL = newSVsv (sv_bless (rv, gv_stashpv(classname, TRUE)));

        if (!hv_fetch (hv, CACHEp, CACHEl, 0))
          hv_store (hv, CACHEp, CACHEl, newRV_noinc ((SV *)newHV ()), CACHEh);

        if (!hv_fetch (hv, TYPEp, TYPEl, 0))
          hv_store (hv, TYPEp,  TYPEl,  newRV_noinc ((SV *)newHV ()), TYPEh);

        sv_magicext ((SV *)hv, Nullsv, PERL_MAGIC_tied, &vtbl_agni_object, Nullch, 0);

        OUTPUT:
        RETVAL

void
rmagical_off(SV *rv)
	ALIAS:
          rmagical_on = 1
	CODE:
        if (ix)
          SvRMAGICAL_on (SvRV (rv));
        else
          SvRMAGICAL_off (SvRV (rv));

void
isobject(SV *rv)
	CODE:
        if (sv_isobject (rv))
          XSRETURN_YES;
        else
          XSRETURN_NO;

MODULE = PApp		PACKAGE = agni::object

void
DESTROY(SV *rv)
	CODE:
        /* turn magic off before destruction, to ease perls job */
        SvRMAGICAL_off (SvRV (rv));

void
FETCH(SV *self, SV *key)
        PPCODE:
        HV *hv = (HV*) SvRV (self);
        char *key_ = SvPV_nolen (key);
        HE *he;
        
        SvRMAGICAL_off (hv);

        /* _-keys go into $self, non-_-keys are store'ed immediately */
        if (key_[0] == '_')
          he = hv_fetch_ent (hv, key, 0, 0);
        else if (key_[0] >= '1' && key_[1] <= '9')
          {
            SV *tobj = obj_by_gid (self, key);

            SvRMAGICAL_on (hv);
            if (!tobj)
              croak ("unable to resolve type '%s' in gid-FETCH", key_);

            PUTBACK; fetch_thaw_push (tobj, self); SPAGAIN;
            return;
          }
        else
          {
            HV *hvc = (HV *)SvRV (*(hv_fetch (hv, CACHEp, CACHEl, 0)));
            he = hv_fetch_ent (hvc, key, 0, 0);

            /* if cached, do not call fetch */
            if (!he)
              {
                hvc = (HV *)SvRV (*(hv_fetch (hv, TYPEp, TYPEl, 0)));
                he = hv_fetch_ent (hvc, key, 0, 0);

                if (he)
                  {
                    SvRMAGICAL_on (hv);
                    PUTBACK; fetch_thaw_push (HeVAL (he), self); SPAGAIN;
                    return;
                  }
                else
                  he = hv_fetch_ent (hv, key, 0, 0);
              }
          }

        if (he)
          XPUSHs (sv_mortalcopy (HeVAL (he)));

        SvRMAGICAL_on (hv);

void
STORE(SV *self, SV *key, SV *value)
        PPCODE:
        HV *hv = (HV*) SvRV (self);
        char *key_ = SvPV_nolen (key);

        SvRMAGICAL_off (hv);

        /* _-keys go into $self, non-_-keys are store'ed immediately */
        if (key_[0] == '_')
          hv_store_ent (hv, key, newSVsv (value), 0);
        else if (key_[0] >= '1' && key_[1] <= '9')
          {
            SV *tobj = obj_by_gid (self, key);

            SvRMAGICAL_on (hv);
            if (!tobj)
              croak ("unable to resolve type '%s' in gid-STORE", key_);

            PUTBACK; freeze_store (tobj, self, value); SPAGAIN;
            return;
          }
        else
          {
            /* now check for a _type entry */
            HV *hvc = (HV *)SvRV (*(hv_fetch (hv, TYPEp, TYPEl, 0)));
            HE *he = hv_fetch_ent (hvc, key, 0, 0);

            if (he)
              {
                SV *tobj = HeVAL (he);

                hvc = (HV *)SvRV (*(hv_fetch (hv, CACHEp, CACHEl, 0)));
                he = hv_fetch_ent (hvc, key, 0, 0);

                /* always update cache, if it exists */
                if (he)
                  {
                    SvREFCNT_dec (HeVAL (he));
                    HeVAL (he) = newSVsv (value);
                  }

                SvRMAGICAL_on (hv);
                PUTBACK; freeze_store (tobj, self, value); SPAGAIN;
                return;
              }
            else
              hv_store_ent (hv, key, newSVsv (value), 0);
          }

        SvRMAGICAL_on (hv);

void
EXISTS(SV *self, SV *key)
        PPCODE:
        HV *hv = (HV*) SvRV (self);
        HV *hvt;
        char *key_ = SvPV_nolen (key);
        
        SvRMAGICAL_off (hv);

        /* check _-keys in $self and non-_-keys in $self->{_type} */
        if (key_[0] == '_')
          hvt = hv;
        else
          hvt = (HV *)SvRV (*(hv_fetch (hv, TYPEp, TYPEl, 0)));

        XPUSHs (sv_2mortal (newSViv (hv_exists_ent (hvt, key, 0))));

        SvRMAGICAL_on (hv);

void
DELETE(SV *self, SV *key)
        PPCODE:
        HV *hv = (HV*) SvRV (self);
        char *key_ = SvPV_nolen (key);
        SV *value;
        
        SvRMAGICAL_off (hv);

        if (key_[0] != '_' || 1)
          {
            value = hv_delete_ent (hv, key, 0, 0);

            if (value)
              XPUSHs (value);
          }

        SvRMAGICAL_on (hv);

void
NEXTKEY(self, ...)
	SV *	self
        ALIAS:
          FIRSTKEY = 1
        PPCODE:
        HV *hv = (HV*) SvRV (self);
        HV *hvt;
        HE *he;

        SvRMAGICAL_off (hv);

        hvt = (HV *)SvRV (*(hv_fetch (hv, TYPEp, TYPEl, 0)));

        if (ix)
          hv_iterinit (hvt);

        he = hv_iternext (hvt);

        if (he)
          XPUSHs (hv_iterkeysv (he));

        SvRMAGICAL_on (hv);


