package PApp::Config;

=head1 NAME

PApp::Config - hold common configuration settings

=over 4

=cut

$VERSION = 0.03;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw();

%papp; # loaded applications
%pimp; # loaded imports

=item @paths = search_path [path...]

Return the standard search path and optionally add additional paths.

=cut

my @incpath;

sub search_path {
   push @incpath, @_;
   @incpath;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

Marc Lehmann <pcg@goof.com>

=cut



