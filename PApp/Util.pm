=head1 NAME

PApp::Util - various utility functions that didn't fit anywhere else

=head1 SYNOPSIS

   use PApp::Util;

=head1 DESCRIPTION

=over 4

=cut

package PApp::Util;

use Carp;
use base 'Exporter';

$VERSION = 0.12;
@EXPORT_OK = qw(format_source dumpval digest append_string_hash uniq);

=item format_source $source

Formats a file supposed to be some "sourcecode" (e.g. perl, papp, xslt etc..)
into formatted ascii. It includes line numbering at the front of each line and
handles embedded "#line" markers.

=cut

sub format_source($) {
   my $data = shift;
   my $s = 1;
   $data =~ s{
      ^(?=\#line\ (\d+))?
   }{
      if ($1) {
         $s = $1;
         "\n";
      } else {
         sprintf "%03d: ", $s++
      }
   }gemx;
   $data;
}

=item dumpval any-perl-ref

Tries to dump the given perl-ref into a nicely-formatted
human-readable-format (currently uses either Data::Dumper or Dumpvalue)
but tries to be I<very> robust about internal errors, i.e. this functions
always tries to output as much usable data as possible without die'ing.

=cut

sub dumpval {
   eval {
      local $SIG{__DIE__};
      my $d;
      if (1) {
         require Data::Dumper;
         $d = new Data::Dumper([$_[0]], ["*var"]);
         $d->Terse(1);
         $d->Indent(2);
         $d->Quotekeys(0);
         $d->Useqq(1);
         #$d->Bless(...);
         $d->Seen($_[1]) if @_ > 1;
         $d = $d->Dump();
      } else {
         local *STDOUT;
         local *PApp::output;
         tie *STDOUT, PApp::Catch_STDOUT;

         require Dumpvalue;
         $d = new Dumpvalue globPrint => 1, compactDump => 0, veryCompact => 0;
         $d->dumpValue($_[0]);
         $d = $PApp::output;
      }
      $d =~ s/([\x00-\x07\x09\x0b\x0c\x0e-\x1f])/sprintf "\\x%02x", ord($1)/ge;
      $d;
   } || "[unable to dump $_[0]: '$@']";
}

=item digest(args...)

Calculate a SHA1 digest and return it base64-encoded. The result will
always be 27 characters long.

=cut

sub digest {
   require Digest::SHA1;
   goto &Digest::SHA1::sha1_base64;
}

=item append_string_hash $hashref1, $hashref2

Appends all the strings found in $hashref2 to the respective keys in
$hashref1 (e.g. $h1->{key} .= $h2->{key} for all keys).

=cut

sub append_string_hash($$) {
   my ($h1, $h2) = @_;
   while (my ($k, $v) = each %$h2) {
      $h1->{$k} .= $h2->{$k};
   }
   $h1;
}

=item @ = uniq @array/$arrayref

Returns all the elements that are unique inside the array/arrayref. The
elements must be strings, or at least must stringify sensibly (to make
sure the results are predictable, always pass in an arrayref).

=cut

sub uniq {
   my %seen;
   my @res;
   for (ref $_[0] ? @{$_[0]} : @_) {
      next if $seen{$_}++;
      push @res, $_;
   }
   @res;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut


