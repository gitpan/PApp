#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef unsigned char uchar;

static uchar e64[ 64] = "0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ.abcdefghijklmnopqrstuvwxyz";
static uchar d64[256];

MODULE = PApp		PACKAGE = PApp

SV *
weaken(sv)
	SV *sv
	CODE:
        RETVAL = SvREFCNT_inc (sv_rvweaken(sv));
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

        RETVAL = NEWSV (0, (len * 4 + 2) / 3);
        SvPOK_only (RETVAL);
        SvCUR_set (RETVAL, (len * 4 + 2) / 3);
        dst = (uchar *)SvPV_nolen (RETVAL);

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

