package PApp::FormBuffer;

=head1 NAME

PApp::FormBuffer - a re-blocking buffer for multipart streams

=head1 SYNOPSIS

 use PApp::FormBuffer;
 # not yet

=head1 DESCRIPTION

In flux ;-> See C<parse_multipart_form> in L<PApp>.

=head2 new attr => val, ...

 fh         filehandle to use (only read()) is ever called
 boundary   the "file"-part boundary
 rsize      max. number of bytes to read

=head2 supported methods

 READ
 READLINE
 EOF

 skip_boundary

=cut

$VERSION = 0.12;

no utf8;

use PApp::Exception;

sub new {
   my $class = shift;
   my $fh = local *PApp_FormBuffer;
   my $self = tie $fh, $class, {
      bufsize => 4096,
      @_,
      buffer => "\15\12",
      datalen => 2,
   };
   $self->_refill($self->{bufsize});
   $self;
}

sub TIEHANDLE {
   my $class = shift;
   my $self = shift;

   bless $self, $class;
}

sub EOF {
   my $self = shift;
   $self->{datalen} == 0;
}

sub _datalen {
   my $self = shift;
   $self->{datalen} = index $self->{buffer}, "--$self->{boundary}";
   $self->{datalen} = length $self->{buffer} if $self->{datalen} < 0;
}

sub skip_boundary {
   my $self = shift;
   while ($self->{datalen} >= length ($self->{buffer})) {
      if (length($self->{buffer}) > 4+length($self->{boundary})) {
         $self->{buffer} = ""; $self->{datalen} = 0;
      }
      $self->_refill($self->{bufsize});
   }
   $self->{buffer} =~ s/.*?--\Q$self->{boundary}//s;
   $self->_datalen;
   #$self->_refill($self->{bufsize});
   $self->READLINE ne "--";
}

sub _refill {
   my $self = shift;
   my $len = shift;

   while ($self->{datalen} < $len && $self->{datalen} >= length($self->{buffer})) {
      my $buf;
      $len = $self->{rsize} if $len > $self->{rsize};
      my $len = $self->{fh}->read($buf, $len);
      $len > 0 or die "unable to read more form data into FormBuffer: $!\n";
      $self->{rsize} -= $len;
      $self->{buffer} .= $buf;
      $self->_datalen;
   }
}

sub READ {
   my $self = shift;
   my $buf = \$_[0];
   my $len = $_[1];
   my $offset = $_[2];
   $self->_refill($len);
   $len = $self->{datalen} if $len > $self->{datalen};
   substr ($$buf, $offset) = substr ($self->{buffer}, 0, $len);
   substr ($self->{buffer}, 0, $len) = ""; $self->{datalen} -= $len;
   $len;
}

sub READLINE {
   my $self = shift;
   for(;;) {
      return undef if $self->{datalen} == 0;
      if ($self->{buffer} =~ s/^([^\15\12]*?)\15?\12//) {
         my $line = $1;
         $self->_datalen;
         return $line;
      }
      $self->_refill(length($self->{buffer}) + $self->{bufsize});
   }
}

*read = \&READ;

=head1 FINAL WORDS

Boy, was this a mess to write :(

=head1 SEE ALSO

L<PApp>.
      
=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

1;
