=head1 NAME

PApp::Util - various utility functions that didn't fit anywhere else

=head1 SYNOPSIS

   use PApp::Util;

=head1 DESCRIPTION

=over 4

=cut

package PApp::Util;

use Carp;
use URI;

use base 'Exporter';

$VERSION = 0.121;
@EXPORT_OK = qw(
      format_source dumpval sv_peek
      digest
      append_string_hash uniq
      find_file fetch_uri load_file
);

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

=item sv_peek $sv

Returns a very verbose dump of the internals of the given sv. Calls the
C<sv_peek> core function. If you don't know what I am talking then this
function is not for you.

=cut

# in PApp.xs currently ;(

=item fetch_uri $uri

Tries to fetch the document specified by C<$uri>, returning C<undef>
on error. As a special "goody", uri's of the form "data:,body" will
immediately return the body part.

=cut

sub fetch_uri {
   my ($uri, $head) = @_;
   if ($uri =~ m%^/|^file:///%i) {
      # simple file URI
      $uri = URI->new($uri, "file")->file;
      return -f $uri if $head;
      local($/,*FILE);
      open FILE, "<", $uri or return ();
      return <FILE>;
   } elsif ($uri =~ s/^data:,//i) {
      return 1 if $head;
      return $uri;
   } else {
      require LWP::Simple;
      return LWP::Simple::head($uri) if $head;
      return LWP::Simple::get($uri);
   }
}

=item find_file $uri [, \@extensions] [, @bases]

Try to locate the specified document. If the uri is a relative uri (or a
simple unix path) it will use the URIs in C<@bases> and PApp's search path
to locate the file. If bases contain an arrayref than this arrayref should
contain a list of extensions (without a leading dot) to append to the URI
while searching the file.

=cut

sub find_file {
   my $file = shift;
   my @ext;
   my %seen;
   for my $path (@_, PApp::Config::search_path) {
      if (ref $path eq "ARRAY") {
         @ext = map ".$_", @$path;
      } else {
         for my $ext ("", @ext) {
            my $uri = URI->new_abs("$file$ext", "$path/");
            next if $seen{"$uri"}++; # optimization, probably not worth the effort
            return $uri if fetch_uri $uri, 1;
         }
      }
   }
   ();
}

=item load_file $uri [, @extensions]

Locate the document specified by the given uri using C<find_file>, then
fetch and return it's contents using C<fetch_uri>.

=cut

sub load_file {
   my $path = &find_file
      or return;
   return fetch_uri $path;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut


