=head1 NAME

PApp::Recode - convert bytes from one charset to another

=head1 SYNOPSIS

 use PApp::Recode;
 # not auto-imported into .papp-files

 $converter = to_utf8 PApp::Recode "iso-8859-1";
 $converter->("string");

=head1 DESCRIPTION

This module creates conversion functions that enable you to convert text
data from one character set (and/or encoding) to another.

#FIXME# this module is certainly NOT finished yet, as PApp itself
currently uses PApp::Recode::Pconv internaly ;->

=cut

package PApp::Recode;

use Convert::Scalar ();

BEGIN {
   $VERSION = 0.142;

   require XSLoader;
   XSLoader::load 'PApp::Recode', $VERSION;
}

=head2 FUNCTIONS

=over 4

=item charset_valid $charset

Returns a boolean indicating wether the named charset is valid on this
system (i.e. can be converted from/to UTF-8).

Currently this function always returns 1. #FIXME#

=cut

my %charset_valid = ( "iso-8859-1" => 1, "utf-8" => 1 );

sub charset_valid {
   unless (exists $charset_valid{$_[0]}) {
      $charset_valid{$cs} = eval {
         PApp::Recode::Pconv::open($cs, "utf-8");
         PApp::Recode::Pconv::open("utf-8", $cs);
         1;
      };
   }
   $charset_valid{$cs};
}

=back

=cut

=head2 THE PApp::Recode CLASS

This class has never been tested, so don't expect it to work.

=over 4

=item $converter = new PApp::Recode "destination-charset", "source-charset" [, \&fallback]

Returns a new conversion function (a code reference) that converts its
argument from the source character set into the destination character set
each time it is called (it does remember state, though. A call without
arguments resets the state).

Perl's internal utf8-flag is ignored on input and not set on output.

=item $converter = to_utf8 PApp::Recode "source-character-set" [, \&fallback]

Similar to a call to C<new> with the first argument equal to "utf-8". The
returned conversion function will, however, forcefully set perl's utf-8
flag on the returned scalar.

=item $converter = utf8_to PApp::Recode "destination-character-set" [, \&fallback]

Similar to a call to C<new> with the second argument equal to "utf-8". The
returned conversion function will, however, upgrade its argument to utf-8.

=cut

sub new($$$;$) {
   my $self = shift;
   my ($to, $from, $fb) = @_;
   my $pconv = PApp::Recode::Pconv::open($to, $from, $fb);
   $pconv && sub {
      unshift @_, $pconv;
      &PApp::Recode::Pconv::convert;
   };
}

sub to_utf8($$;$) {
   my $self = shift;
   my $converter = $self->new("utf-8", $_[0], $_[1]);
   sub {
      Convert::Scalar::utf8_on &$converter;
   };
}

sub utf8_to($$;$) {
   my $self = shift;
   my $converter = $self->new($_[0], "utf-8", $_[1]);
   sub {
      Convert::Scalar::utf8_upgrade($_[0]) if @_;
      &$converter;
   };
}

=back

=head2 THE PApp::Recode::Pool CLASS

NYI

=over 4

=back

=head2 THE PApp::Recode::Pconv CLASS

This is the class that actually implements character conversion. It should not be used directly.

=cut

=over 4

=item new PApp::Recode::Pconv tocode, fromcode [, fallback]

=item PApp::Recode::Pconv::open tocode, fromcode [, fallback]

=item $pconv->convert($string [, reset])

=item $pconv->reset

=item $pconv->convert_fresh($string)

=cut

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

1;

