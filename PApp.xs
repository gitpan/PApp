#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if _POSIX_SOURCE
#include <unistd.h>
#endif
#include <string.h>

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
  HV *hv;
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

#define SURL_STYLE    0x41
#define SURL_FILENAME 0x42
#define SURL_PUSH     0x01
#define SURL_POP      0x81
#define SURL_UNSHIFT  0x02
#define SURL_SHIFT    0x82

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
      sv_setsv (sv, rv);
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
    sv = SvRV (arg);
  else if (may_delete)
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

  /*
   * the following is insane (??) or am I, because I wrotwe it originally (??)
  if (SvCUR (r) > 1 && SvEND(r)[-1] == '/')
    SvCUR_set (r, SvCUR (r) - 1);
  */

  /*fprintf (stderr, "expanding %s (%s) into %s\n", SvPV_nolen(path), cwd, SvPV_nolen (r)); /*D*/
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
      SV *module;
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

/*****************************************************************************/

MODULE = PApp		PACKAGE = PApp

BOOT:
{
  cipher_e    = gv_fetchpv ("PApp::cipher_e"   , TRUE, SVt_PV);
  pmod        = gv_fetchpv ("PApp::pmod"       , TRUE, SVt_PV);
  curpath     = gv_fetchpv ("PApp::curpath"    , TRUE, SVt_PV);
  curprfx     = gv_fetchpv ("PApp::curprfx"    , TRUE, SVt_PV);
  location    = gv_fetchpv ("PApp::location"   , TRUE, SVt_PV);
  big_a       = gv_fetchpv ("PApp::A"          , TRUE, SVt_PV);
  big_p       = gv_fetchpv ("PApp::P"          , TRUE, SVt_PV);
  big_s       = gv_fetchpv ("PApp::S"          , TRUE, SVt_PV);
  state       = gv_fetchpv ("PApp::state"      , TRUE, SVt_PV);
  arguments   = gv_fetchpv ("PApp::arguments"  , TRUE, SVt_PV);
  userid      = gv_fetchpv ("PApp::userid"     , TRUE, SVt_IV);
  stateid     = gv_fetchpv ("PApp::stateid"    , TRUE, SVt_IV);
  sessionid   = gv_fetchpv ("PApp::sessionid"  , TRUE, SVt_IV);
  module      = gv_fetchpv ("PApp::module"     , TRUE, SVt_PV);
  modules     = gv_fetchpv ("PApp::modules"    , TRUE, SVt_PV);
  surlstyle   = gv_fetchpv ("PApp::surlstyle"  , TRUE, SVt_IV);
}

# the most complex piece of shit
void
surl(...)
	PROTOTYPE: @
	PPCODE:
{
        int i = 0;
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

        if (items & 1)
          {
            dstmodule = ST(i);
            i++;
          }
        else
          dstmodule = GvSV (module);

        if (SvROK (dstmodule))
          {
            if (SvTYPE (SvRV (dstmodule)) != SVt_PV)
              croak ("surl: destination module must be either scalar or ref to scalar");

            pathinfo = newSVsv (SvRV (dstmodule));
          }
        else
          pathinfo = eval_path (dstmodule);

        xcurprfx = SvPV (GvSV (curprfx), lcurprfx);

        av_push (args, pathinfo);

        for (; i < items; i += 2)
          {
            SV *arg = ST(i  );
            SV *val = ST(i+1);

            if (SvROK (arg))
              {
                arg = newSVsv (arg);
                val = newSVsv (val);
              }
            else if (SvCUR (arg) == 2 && !*SvPV_nolen (arg))
              /* do not expand SURL_xxx constants */
              {
                int surlmod = (unsigned char)SvPV_nolen (arg)[1];

                if (surlmod == SURL_STYLE)
                  {
                    style = SvIV (val);
                    continue;
                  }
                else if (surlmod == SURL_FILENAME)
                  {
                    path = val;
                    continue;
                  }
                else if (surlmod == SURL_POP || surlmod == SURL_SHIFT)
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

            /*fprintf (stderr, "prefixing %s gives %s\n", SvPV_nolen(ST(i)), SvPV_nolen(arg));/*D*/

            av_push (args, arg);
            av_push (args, val);
          }

        {
          AV *av;
          SV **he = hv_fetch ((HV *)GvHV (state), "papp_alternative", 16, 0);

          if (!he || !SvROK ((SV *)*he))
            croak ("$state{papp_alternative} not an arrayref");

          av = (AV *)SvRV ((SV *)*he);
          av_push (av, newRV_noinc ((SV *) args));
          xalternative = av_len (av);
        }

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

            surl = newSVsv (GvSV (location));
            sv_catpvn (surl, "/", 1);
            sv_catsv (surl, pathinfo);
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

            XPUSHs (sv_2mortal (surl));
            if (style == 3)
              XPUSHs (sv_2mortal (newSVpvn (key, x64_enclen (16))));
          }
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
                          sv_setsv (sv, val);
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

# destroy %P, %S, %A and %state, but do not call DESTROY
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

