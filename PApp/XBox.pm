=head1 NAME

PApp::XBox - papp execution environment for perl files

=head1 SYNOPSIS

 use PApp::XBox qw(domain=translation-domain);

=head1 DESCRIPTION

Unlike the real XBox, this module makes working anti-aliasing a reality!

Seriously, sometimes you want the normal PApp execution environment
in normal Perl modules. More often, you

=over 4

=cut

package PApp::XBox;

$VERSION = 0.2;

use PApp::PCode ();
use PApp::Util ();

1;

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

