=head1 NAME

PApp::PCode - PCode compiler/decompiler and various other utility functions.

=head1 SYNOPSIS

=head1 DESCRIPTION

PApp stores a lot of things in pcode format, which is simply an escaping
mechanism to store pxml/xml/html/pelr sections inside a single data
structure that can be efficiently converted to pxml or perl code.

You will rarely if ever need to use this module directly.

=over 4

=cut

package PApp::PCode;

use Carp;
use Convert::Scalar ':utf8';

use PApp::Exception;

use base 'Exporter';

no bytes;
use utf8;

$VERSION = 0.122;
@EXPORT_OK = qw(pxml2pcode xml2pcode perl2pcode pcode2pxml pcode2perl);

=item pxml2pcode "phtml or pxml code"

Protect the contents of the phtml or pxml string (xml with embedded perl
sections), i.e. make it an xml-parseble-document by resolving all E<lt>: and
E<lt>? sections.

The following four mode-switches are allowed, the initial mode is ":>"
(i.e. non-interpolated html/xml). You can force the initial mode to ":>"
by prefixing the string with "E<lt>:?>".

 <:	start verbatim perl section ("perl-mode")
 :>	start plain string section (non-interpolated string)
 <?	start perl expression (single expr, result will be interpolated)
 ?>	start interpolated string section (similar to qq[...]>) DEPRECATED
        will soon mean the same as :>

Within plain and interpolated string sections you can also use the
__I<>"string" construct to mark (and map) internationalized text. The
construct must be used verbatim: two underlines, one double-quote, text,
and a trailing double-quote. For more complex uses, just escape to perl
(e.g. <?__I<>"xxx"?>).

In string sections (and only there!), you can also use preprocessor
commands (the C<#> must be at the beginning of the line, between the C<#>
and the command name can be any amount of white space, just like in C!)

 #if any_perl_condition
   any phtml code
 #elsif any_perl_conditon
   ...
 #else
   ...
 #endif

Preprocessor-commands are ignored at the very beginning of a string
section (that is, they must follow a linebreak). They are I<completely>
removed on output (i.e. the linebreak before and after it will not be
reflected in the output).

White space will be mostly preserved (especially line-number and
-ordering).

=begin comment

And also these experimental preprocessor commands (these currently trash
the line number info, though!)

 #?? condition ?? if-yes-phtml-code
 #?? condition ?? if-yes-phtml-code ?? if-no-phtml-code

=end comment

=item xml2pcode "string"

Convert the string into pcode without interpreting it.

=item perl2pcode "perl source"

Protect the given perl sourcecode, i.e. convert it in a similar way as
C<phtml_to_pcode>.

=item pcode2perl $pcode

Convert the protected xml/perl code into vanilla perl that can be
eval'ed. The result will have the same number of lines (in the same order)
as the original perl or xml source (important for error reporting).

=cut

# just quote all xml-active characters into almost-quoted-printable
sub _quote_perl($) {
   join "\012",
      map unpack("H*", $_),
         split /\015?\012/, $_[0], -1;
}

# be liberal in what you accept, stylesheet processing might
# gar|ble our nice line-endings
sub _unquote_perl($) {
   use bytes;
   utf8_on
      join "\n",
         map pack("H*", $_),
            split /[ \011\012\015]/, $_[0], -1;
}

my ($dx, $dy, $dq);
BEGIN {
   if ($] < 5.007) {
      die "perl 5.7 is required for this part, see the sourcecode at the point of this error to find out more";
   }
   # we use some characters in the compatibility zone,
   # namely the character block 0xfce0-0xfcef
   ($dx, $dy, $dq) = (
	"\x{fce0}",
	"\x{fce1}",
	"\x{fce2}",
   );
}

# pcode  := string tail | EMPTY
# tail   := code pcode | EMPTY
# string := ( $dx | $dy ) $dq-quotedstring
# code   := ( $dx | $dy ) hex-quotedcode

sub pxml2pcode($) {
   my $data = ":>" . shift;
   my $mode;
   my $res = "";#d#

   $data =~ s/^:><:\?>/?>/;

   utf8_upgrade $data; # force utf-8-encoding

   for(;;) {
      # STRING
      $res .= $dx;
      $data =~ /\G([:?])>((?:[^<]+|<[^:?])*)/gcs or last;
      $mode = $1 eq ":" ? $dx : $dy;

      # do preprocessor commands, __-string-processing and quoting
      for (my $src = $2) {
         for (;;) {
            m/\G\n#\s*if\s(.*)(\n(?=[^#])|$)/gcm	and ($res .= "$dx\n" . (_quote_perl "if ($1) {") . "$2$dx"), redo;
            m/\G\n#\s*els?if\s(.*)(\n(?=[^#])|$)/gcm	and ($res .= "$dx\n" . (_quote_perl "} elsif ($1) {") . "$2$dx"), redo;
            m/\G\n#\s*else\s*(\n(?=[^#])|$)/gcm		and ($res .= "$dx\n" . (_quote_perl "} else {") . "$1$dx"), redo;
            m/\G\n#\s*endif\s*(\n(?=[^#])|$)/gcm	and ($res .= "$dx\n" . (_quote_perl "}") . "$1$dx"), redo;
            m/\G(\x5f\x5f"(?:(?:[^"\\]+|\\.)*)")/gcs	and ($res .= $dy . (_quote_perl $1) . $dx), redo; # __
            m/\G([$dx$dy$dq])/gco			and ($res .= "$dq$1"), redo;
            $mode eq $dy && m/\G([\$\@])/gcs		and ($res .= "$dx$dy$1"), redo;
            m/\G(.[^_$dx$dy$dq\$\@\n]*)/gcso		and ($res .= $1), redo;
            last;
         }
      }

      # CODE
      $data =~ /\G<([:?])((?:[^:?]+|[:?][^>])*)/gcs or last;
      $mode = $1 eq ":" ? $dx : $dy;
      $res .= $mode;
      $res .= _quote_perl $2;

   }
   $data !~ /\G(.{1,20})/gcs or croak "trailing characters in xml string ($1)";
   substr $res, 1;
}

sub perl2pcode($) {
   $dx . (_quote_perl shift) . $dx;
}

sub xml2pcode($) {
   my $data = shift;
   $data =~ s/([$dx$dy$dq])/$dq$1/go;
   $data;
}

sub pcode2perl($) {
   my $pcode = $dx . $_[0];
   my ($mode, $src);
   my $res = "";#d#
   for (;;) {
      # STRING
      $pcode =~ /\G([$dx$dy])((?:[^$dx$dy$dq]+|$dq [$dx$dy$dq])*)/xgcso or last;
      ($mode, $src) = ($1, $2);
      $src =~ s/$dq(.)/$1/g;
      if ($src ne "") {
         $mode = $mode eq $dx ? '' : 'qq';
         if (0&&$mode ne $dx) { #d# warn about deprecated construct ?>xxx
            $src =~ /\\/
               and warn "unneccessary quoting in deprecated ?> construct: $src";
            $src =~ /\$/
               and warn "probable scalar access in deprecated ?> construct: $src";
            $src =~ /\@/
               and warn "probable array access in deprecated ?> construct: $src";
         }
         $src =~ s/\\/\\\\/g; $src =~ s/'/\\'/g;
         utf8_on $src; #d# #FIXME##5.7.0# bug, see testcase #1
         $res .= "\$PApp::output .= $mode'$src';";
      }

      # CODE
      $pcode =~ /\G([$dx$dy])([0-9a-f \010\012\015]*)/gcso or last;
      ($mode, $src) = ($1, $2);
      $src = _unquote_perl $src;
      if ($src !~ /^[ \t]*$/) {
         if ($mode eq $dy) {
            $src =~ s/;\s*$//; # remove a single trailing ";"
            $src = "do { $src }" if $src =~ /;/; # wrap multiple statements into do {} blocks
            $res .= "\$PApp::output .= ($src);";
         } else {
            $res .= "$src;";
         }
      }
   }
   $pcode !~ /\G(.{1,20})/gcs or die "internal error: trailing characters in pcode-string ($1)";
   $res;
}

# mostly for debugging
sub pcode2pxml($) {
   my $pcode = $dx . shift;
   my ($mode, $src);
   my $res = "";#d#
   for (;;) {
      # STRING
      $pcode =~ /\G([$dx$dy])((?:[^$dx$dy$dq]+|$dq [$dx$dy$dq])*)/xgcso or last;
      ($mode, $src) = ($1, $2);
      $src =~ s/$dq(.)/$1/g;
      $res .= $mode eq $dx ? ":>" : "?>";
      $res .= $src;

      # CODE
      $pcode =~ /\G([$dx$dy])([0-9a-f \010\012\015]*)/gcso or last;
      ($mode, $src) = ($1, $2);
      $src = _unquote_perl $src;
      $res .= $mode eq $dx ? "<:" : "<?";
      $res .= $src;
   }
   $pcode !~ /\G(.{1,20})/gcs or die "internal error: trailing characters in pcode-string ($1)";
   $res = substr $res, 2;
   $res =~ s/:><://g;
   $res;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

