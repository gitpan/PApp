=head1 NAME

PApp::HTML - utility functions for html generation

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

package PApp::HTML;

#   imports
use Carp;
use FileHandle ();

BEGIN {
   $VERSION = 0.02;
   @ISA = qw/Exporter/;
   @EXPORT = qw(

         errbox

         alink mailto_url filefield param submit textfield password_field
         textarea escape_html escape_uri hidden unixtime2http checkbox
         radio reset_button

   );
}

=head1 FUNCTIONS

=over 4

=cut

sub escape_html($) {
   local $_ = shift;
   s/([<>&\x00-\x07\x09\x0b\x0d-\x1f\x80-\x9f])/sprintf "&#%d;", ord($1)/ge;
   $_;
}

sub escape_uri($) {
   local $_ = shift;
   s/([()<>%&?, ='"\x00-\x1f\x80-\x9f])/sprintf "%%%02X", ord($1)/ge;
   $_;
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

Create "a link" (a href) with the given contents, pointing at the given url.

=cut

# "link content, url"
sub alink {
   "<a href=\"$_[1]\">$_[0]</a>";
}

=item errbox $error, $explanation

Render a two-part error-box, very distinctive, very ugly, very visible!

=item submit

=item reset_button

*FIXME*

=cut

sub errbox {
   "<table border=5 width=\"100%\" cellpadding=\"10mm\">"
   ."<tr><td bgcolor=\"#ff0000\"><font color=\"#000000\" size=\"+2\"><b>$_[0]</b></font>"
   ."<tr><td bgcolor=\"#c0c0ff\"><font color=\"#000000\" size=\"+1\"><b><pre>$_[1]</pre></b>&nbsp;</font>"
   ."</table>";
}

sub submit {
   "<input type=submit name=$_[0]".(@_>1 ? " value=\"$_[1]\"" : "").">";
}

sub reset_button {
   "<input type=reset name=$_[0]".(@_>1 ? " value=\"$_[1]\"" : "").">";
}

sub input_field {
   my $t = shift;
   unshift @_, "name" if @_ & 1;
   my $r = "<$t";
   while (@_) {
      $r .= " ".shift;
      $r .= "=\"".escape_html($_[0])."\"" if defined $_[0];
      shift;
   }
   $r.">";
}

=item textfield

=item textarea

=item password_field

=item hidden key => value

=item checkbox

=item radio

=item filefield

*FIXME*

=cut

sub password_field	{ input_field "input type=password", @_ }
sub textfield		{ input_field "input type=text", @_ }
sub textarea		{ input_field "textarea", @_ }
sub hidden		{ input_field "input type=hidden", @_ }
sub checkbox		{ input_field "input type=checkbox", @_ }
sub radio		{ input_field "input type=radio", @_ }
sub filefield		{ input_field "input type=file", @_ }

=item mailto_url $mailaddr, key => value, ...

Create a mailto url with the specified headers (see RFC 2368). All
values will be scaped for you. Example:

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

sub unescape {
   local $_ = shift;
   y/+/ /;
   s/%([0-9a-fA-F][0-9a-fA-F])/pack "c", hex $1/ge;
   $_;
}

# parse application/x-www-form-urlencoded
sub parse_params {
   for (split /[&;]/, $_[0]) {
      /([^=]+)=(.*)/ and $param{$1} = unescape $2;
   }
}

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/



