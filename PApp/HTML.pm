=head1 NAME

PApp::HTML - utility functions for html generation

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

package PApp::HTML;

#   imports
use Carp;
use FileHandle ();

use base Exporter;

use utf8;
no bytes;

$VERSION = 0.12;
@EXPORT = qw(

      errbox

      xmltag

      alink mailto_url filefield param submit textfield password_field
      textarea escape_html escape_uri escape_attr hidden unixtime2http
      checkbox radio reset_button submit_image selectbox javascript button
);

=head1 FUNCTIONS

=over 4

=item escape_html $arg

Returns the html-escaped version of C<$arg> (escaping characters like '<'
and '&', as well as any whitespace characters other than space, cr and
lf).

=item escape_uri $arg

Returns the uri-escaped version of C<$arg>, escaping characters like ' '
(space) and ';' into url-escaped-form using %hex-code. This function
encodes characters with code >255 as utf-8 characters.

=item escape_attr $arg

Returns the attribute-escaped version of C<$arg> (it also wraps its
argument into single quotes, so don't do that yourself).

=cut

use Convert::Scalar ();  # 5.7 bug workaround #d# #FIXME#

sub escape_html($) {
   local $_ = shift;
   Convert::Scalar::utf8_upgrade($_);
   s/([<>&\x00-\x07\x09\x0b\x0d-\x1f\x7f-\x9f])/sprintf "&#%d;", ord($1)/ge;
   Convert::Scalar::utf8_on($_); # 5.7 bug workaround #d# #FIXME#
}

sub escape_uri($) {
   local $_ = shift;
   Convert::Scalar::utf8_upgrade($_);
   use bytes;
   s/([;\/?:@&=+\$,()<>% '"\x00-\x1f\x7f-\xff])/sprintf "%%%02X", ord($1)/ge;
   #Convert::Scalar::utf8_on($_); # 5.7 bug workaround #d# #FIXME# unnecesasary
}

sub escape_attr($) {
   local $_ = shift;
   Convert::Scalar::utf8_upgrade($_);
   s/(['<>&\x00-\x1f\x80-\x9f])/sprintf "&#%d;", ord($1)/ge;
   Convert::Scalar::utf8_on($_); # 5.7 bug workaround #d# #FIXME#
   "'$_'";
}

my @MON  = qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
my @WDAY = qw/Sun Mon Tue Wed Thu Fri Sat/;

# format can be 'http' (defaut) or 'cookie'
sub unixtime2http {
   my($time, $format) = @_;

   my $sc = $format eq "cookie" ? '-' : ' ';

   my ($sec,$min,$hour,$mday,$mon,$year,$wday) = gmtime $time;

   sprintf "%s, %02d$sc%s$sc%04d %02d:%02d:%02d GMT",
           $WDAY[$wday], $mday, $MON[$mon], $year+1900,
           $hour, $min, $sec;
}

=item $ahref = alink contents, url

Create "a link" (a href) with the given contents, pointing at the given
url. It uses single quotes to delimit the url, so watch out and escape
yourself!

=cut

# "link content, url"
sub alink {
   "<a href='$_[1]'>$_[0]</a>";
}

=item errbox $error, $explanation

Render a two-part error-box, very distinctive, very ugly, very visible!

=cut

sub errbox {
   "<table border=\"5\" width=\"100%\" cellpadding=\"10mm\">"
   ."<tr><td bgcolor=\"#ff0000\"><font color=\"#000000\" size=\"+2\"><b>$_[0]</b></font></td></tr>"
   ."<tr><td bgcolor=\"#c0c0ff\"><font color=\"#000000\" size=\"+1\"><b><pre>$_[1]</pre></b>&#160;</font></td></tr>"
   ."</table>";
}

# tag $tag, $attr, $content...

sub _tag {
   my $tag = shift;
   my $r = "<$tag";
   if (ref $_[0] eq "HASH") {
      my $attr = shift;
      while (my ($k, $v) = each %$attr) {
         $r .= " $k=" . escape_attr($v);
      }
   }
   if (@_ or $tag !~ /^(?:img|br|input)$/i) {
      $r .= ">";
      $r .= (join "", @_)."</$tag>" if @_;
   } else {
      $r .= " />"; # space for compatibility
   }
   $r;
}

*xmltag = \&_tag;

=back

=head2 Convinience Functions to Create XHTML Elements

The following functions are shortcuts to various often-used html tags
(mostly form elements). All of them allow an initial 
argument C<attrs> of type hashref which can contain attribute => value
pairs. Attributes always required for the given element (e.g.
"name" for form-elements) can usually be specified directly without using
that hash. C<$value> is usually the initial state/content of the
input element (e.g. some text for C<textfield> or boolean for C<checkbox>).

=over 4

=item submit [\%attrs,] $name [, $value]

=item submit_image [\%attrs,] $name, $img_url [, $value]

Submits a graphical submit button. C<$img_url> must be the url to the image that is to be used.

=item reset_button [\%attrs,] $name 

*FIXME*

=item textfield [\%attrs,] $name [, $value]

Creates an input element of type text named C<$name>. Examples:

   textfield "field1";
   textfield "field1", "some text";
   textfield { maxlength => 20 }, "field1";

=item textarea [\%attrs,] $name, [, $value]

Creates an input element of type textarea named C<$name>

=item password_field [\%attrs,] $name [, $value]

Creates an input element of type password named C<$name>

=item hidden [\%attrs,] $name [, $value]

Creates an input element of type hidden named C<$name>

=item checkbox [\%attrs,] $name [, $value [, $checked]]

Creates an input element of type checkbox named C<$name>

=item radio [\%attrs,] $name [, $value [, $checked]]

Creates an input element of type radiobutton named C<$name>

=item filefield [\%attrs,] $name [, $value]

Creates an input element of type file named C<$name>

=cut

sub submit		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift || "", type => 'submit' } }
sub submit_image	{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, src => shift, value => shift || "", type => 'image' } }
sub reset_button	{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, type => 'reset' } }
sub password_field	{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, type => 'password' } }
sub textfield		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, type => 'text'     } }
sub button		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, type => 'button'   } }
sub hidden		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, type => 'hidden'   } }
sub checkbox		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, (shift) ? (checked => "checked") : (), type => 'checkbox' } }
sub radio		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, (shift) ? (checked => "checked") : (), type => 'radio'    } }
sub filefield		{ _tag "input", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift, value => shift, type => 'file'     } }

sub textarea		{ _tag "textarea", { ref $_[0] eq "HASH" ? %{+shift} : (), name => shift }, "\n", @_ }

=item selectbox name, [], attr => value... NYI

die! die! die!

=cut

# not yet implemented
sub selectbox {
   die;
   my $option = splice @_, 1, 1, ();
   input_field("select", @_);
   while (@$option) {
      my ($key, $val) = splice @$option, 0, 2, ();
   }
   #PApp::echo("</select>");
}

=item javascript $code

Returns a script element containing correctly quoted code inside a comment
as recommended in HTML 4. Every occurence of C<--> will be replaced by
C<-\-> to avoid generating illegal syntax (for XHTML compatibility). Yes,
this means that the decrement operator is certainly out. One would expect
browsers to properly support entities inside script tags, but of course
they don't, ruling better solutions totally out.

If you use a stylesheet, consider something like this for your head-section:

   <script type="text/javascript" language="javascript1.3" defer="defer">
      <xsl:comment>
         <xsl:text>&#10;</xsl:text>
         <xsl:for-each select="descendant::script">
            <xsl:text disable-output-escaping="yes"><xsl:value-of select="text()"/></xsl:text>
         </xsl:for-each>
         <xsl:text>//</xsl:text>
      </xsl:comment>
   </script>

=cut

sub javascript($) {
   my $code = shift;
   $code =~ s/--/-\\-/g;
   "<script type='text/javascript'><!--\n$code\n// --></script>";
}

=item mailto_url $mailaddr, key => value, ...

Create a mailto url with the specified headers (see RFC 2368). All values
will be properly escaped for you. Example:

 mailto_url "pcg@goof.com",
            subject => "Mail from me",
            body => "(generated from ".reference_url(1).")";

=cut

sub mailto_url {
   my $url = "mailto:".shift;
   if (@_) {
      $url .= "?";
      for(;;) {
         my $key = shift;
         my $val = shift;
         $url .= $key."=".escape_uri($val);
         last unless @_;
         $url .= "&amp;";
      }
   }
   $url;
}

sub unescape($) {
   local $_ = $_[0];
   y/+/ /;
   s/%([0-9a-fA-F][0-9a-fA-F])/pack "c", hex $1/ge;
   $_;
}

# parse application/x-www-form-urlencoded
sub parse_params($) {
   map { /([^=]+)(?:=(.*))?/ and (unescape $1, unescape $2) } split /[&;]/, $_[0];
}

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

