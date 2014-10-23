if (!defined $PApp::Apache::_compiled) { eval do { local $/; <DATA> }; die if $@ } 1;
__DATA__

#line 5 "(PApp/Apache.pm)"

=head1 NAME

PApp::Apache - multi-page-state-preserving web applications

=head1 SYNOPSIS

   #   Apache's httpd.conf file
   #   mandatory: activation of PApp
   PerlModule PApp::Apache

   # configure the perl module
   <Perl>
      search_path PApp "/root/src/Fluffball/macro";
      search_path PApp "/root/src/Fluffball";
      configure PApp (
         cipherkey => "f8da1b96e906bace04c96dbe562af9x31957b44e4c282a1658072f0cbe6ba44d",
         pappdb    => "DBI:mysql:papp",
         checkdeps => 1,
      );

      # mount an application (here: dbedit.papp)
      mount_appset PApp (
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
use Apache::Constants ();
use FileHandle ();
use File::Basename qw(dirname);

use PApp;
use PApp::Exception;
use PApp::Package;

BEGIN {
   @ISA = PApp::Base::;
   unshift @PApp::ISA, __PACKAGE__;
   $VERSION = 0.142;
}

*PApp::OK = \&Apache::Constants::OK;

sub config_error {
   my $self = shift;
   my $err = shift;
   warn "$err\nPApp: error during configuration caught, skipping some stages\n";
}

sub ChildInit {
   unless (PApp::configured_p) {
      warn "FATAL: 'configured PApp' was never called, disabling PApp";
   }

   eval { PApp::SQL::reinitialize() };
   eval { PApp::Env::DBH->disconnect() };
   eval { PApp::I18n::flush_cache() };
   undef $PApp::Env::DBH;

   PApp->event('childinit');
}

sub apache_config_package {
   my $level = 0;
   1 while (caller(++$level))[0] =~ /^PApp/;
   (caller($level))[0];
}

sub interface {
   qw(PApp::Apache 1.0);
}

sub configure {
   my $self = shift;
   my $cfg = apache_config_package;
   #${"${cfg}::PerlInitHandler"} = "PApp::Apache::Init";
   ${"${cfg}::PerlChildInitHandler"} = "PApp::Apache::ChildInit";
   $self->SUPER::configure(@_);
}

sub mount {
   my $self = shift;
}

sub mount {
   my $self = shift;
   my $papp = shift;

   $self->SUPER::mount($papp, @_);

   my $appid = $papp->{appid};

   my $handler = "PApp::Apache::handler_for_appid_".$appid;
   my %papp_handler = (
         SetHandler  => 'perl-script',
         PerlHandler => $handler,
   );

   *$handler = sub {
      package PApp;
      $request = $_[0];
      $PApp::papp = $papp;

      $location = $request->uri;
      $pathinfo = $request->path_info;
      substr ($location, -length $pathinfo) = "" if $pathinfo;

      _handler;
   };

   my $mountconfig = $papp->{mountconfig};
   if ($mountconfig !~ /%papp_handler/) {
      # INSECURE, should check for empty string instead (TYPOE!)#FIXME#d#
      warn "$papp->{path} [appid=$appid]: mountconfig does not contain '%papp_handler', mounting on '/$papp->{name}'\n";
      $mountconfig = "\$Location{'~ ^/$papp->{name}(/|\$)'} = \\%papp_handler";
   };

   my $package = apache_config_package;

   eval "package $package; $mountconfig";
   $@ and fancydie "error while evaluating mountconfig", "$@",
                   info => [app => "$papp->{path} [appid=$appid]"],
                   info => [mountconfig => $mountconfig];

   $papp;
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

=cut


