#if (!defined $PApp::Apache::compiled) { eval do { local $/; <DATA> }; die $@ if $@ } 1;
#__DATA__
#
##line 5 "(PApp::Apache source)"

=head1 NAME

PApp::Apache - multi-page-state-preserving web applications

=head1 SYNOPSIS

   #   Apache's httpd.conf file
   #   mandatory: activation of PApp
   PerlModule PApp

   # configure the perl module
   <Perl>
      search_path PApp "/root/src/Fluffball/macro";
      search_path PApp "/root/src/Fluffball";
      configure PApp (
         cipherkey => "f87a1b96e906bace04c96dbe562af9731957b44e4c282a1658072f0cbe6ba440",
         pappdb    => "DBI:mysql:papp",
         checkdeps => 1,
      );

      # mount an application (here: dbedit.papp)
      mount PApp (
         location => "/dbedit",
         src => "dbedit.papp"
      );
      configured PApp; # mandatory
   </Perl>

=head1 DESCRIPTION

=over 4

=cut

package PApp::Apache;

use Carp;
use Apache ();
use Apache::Debug;
use Apache::Constants qw(:common);
use FileHandle ();
use File::Basename qw(dirname);

use PApp;
use PApp::Parser;

$VERSION = 0.04;

*PApp::apache_request = \&Apache::request;

sub ChildInit {
   unless (PApp::configured_p) {
      warn "FATAL: 'configured PApp' was never called, disabling PApp";
   }
   PApp::event('childinit');
}

sub mount {
   my $class = shift;
   my $caller = caller;
   my %args = @_;
   my $location = delete $args{location};
   my $config   = delete $args{config};
   my $src      = delete $args{src};
   my $path     = PApp::expand_path($src);
   $path or die "papp-module '$src' not found\n";
   #${"${caller}::PerlInitHandler"} = "PApp::Apache::Init";
   ${"${caller}::PerlChildInitHandler"} = "PApp::Apache::ChildInit";
   ${"${caller}::Location"}{$location} = {
         SetHandler  => 'perl-script',
         PerlHandler => 'PApp::handler',
         %args,
   };
   $PApp::papp{$location} = PApp::reload_app $path, $config;
}

<<'EOF';
#
#   optional Apache::Status information
#
Apache::Status->menu_item(
    'PApp' => 'PApp status',
    sub {
        my ($r, $q) = @_;
        push(@s, "<b>Status Information about PApp</b><br>");
        return \@s;
    }
) if Apache->module('Apache::Status');
EOF

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/



