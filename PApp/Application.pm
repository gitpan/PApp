=head1 NAME

PApp::Application - a class representing a single mountable application

=head1 SYNOPSIS

   use PApp::Application;

   # you don't normally use this class directly

=head1 DESCRIPTION

What?

=over 4

=cut

package PApp::Application;

use PApp::Config qw(DBH);
use PApp::Util;
use PApp::SQL;
use PApp::Exception;
use PApp::Package;
use PApp::I18n ();

use Convert::Scalar ();

use utf8;
no bytes;

$VERSION = 0.122;

=item $papp = new PApp::Application args...

=cut

sub new {
   my $class = shift;
   my $self = bless { @_ }, $class;

   my $path = PApp::Util::find_file $self->{path}, ["papp"];

   -f $path or fancydie "papp-application '$self->{path}' not found\n";

   $self->{path} = $path;

   $self;
}

=item $papp->mount

Do neccessary bookkeeping to mount an application.

=cut

sub mount {
   my $self = shift;
   my %args = @_;

   $self->load_config;

   delete $self->{cb_src}; # not needed for mounted applications

   $self->for_all_packages(sub {
      my ($ppkg, $path, $name) = @_;
      $PApp::preferences{"$path/$name"} = [keys %{$ppkg->{preferences}}] if $ppkg->{preferences};
   });

}

=item $ppkg->preprocess

Parse the package (includign all subpackages) and store the configuration
and code data in the PApp Package Cache(tm) for use by load_config and
load_code.

=cut

sub preprocess {
   my $self = shift;

   my($R, $W); pipe $R, $W;

   my $pid = fork; # do not waste precious memory

   if ($pid == 0) {
      close $R;

      #print "gdb /usr/app/sbin/httpd $$\n"; #<STDIN>;

      eval {
         PApp::SQL::reinitialize;
         local $PApp::SQL::DBH = DBH;

         require PApp::Parser;
         ($ppkg, $code) = PApp::Parser::parse_file($self, $self->{path});

         Storable::store_fd [
            Storable::nfreeze({
               root => $ppkg,
               file => $self->{file},
               translate => $self->{translate},
            }),
            Storable::nfreeze($code),
         ], $W;
      };

      if ($@) {
         local $Storable::forgive_me = 1;
         Storable::store_fd [undef, $@], $W;
      }

      close $W;
      &PApp::Util::_exit;
      exit(255); # just in case, for some reason, this gets propagated to the client
   } elsif ($pid > 0) {
      close $W;

      my ($config, $code) = eval { my ($config, $code) = @{Storable::retrieve_fd $R} };
      close $R;

      waitpid $pid, 0;

      if ($?) {
         require POSIX;
         if (($? & 127) == &POSIX::SIGSEGV) {
            die "\nchild died with SIGSEGV while parsing...\ndid you remember to disable expat while compiling apache?\nyou lost";
         }
      }

      die $code unless $config; # config is undef on error

      sql_exec DBH,
               "replace into pkg (id, ctime, config, code) values (?, NULL, ?, ?)",
               $self->{path}, $config, $code;
   } else {
      fancydie "unable to fork to preprocess";
   }
}

my @config = qw(file root);

sub load_config {
   my $self = shift;

   return if $self->{root};

   my ($ctime, $config) = sql_fetch DBH, "select ctime, config from pkg where id = ?", $self->{path};

   unless ($config) {
      $self->preprocess;
      ($ctime, $config) = sql_fetch DBH, "select ctime, config from pkg where id = ?", $self->{path};
   }

   $config or fancydie "load_config: unable to compile package", $self->{path};

   $config = Storable::thaw $config;

   $self->{ctime} = $ctime;
   while (my ($k, $v) = each %$config) {
      $self->{$k} = $v;
   }

   $self->check_deps;
}

sub load_code {
   my $self = shift;

   return if $self->{compiled};

   $self->load_config;

   $self->{path} or fancydie "can't load_code pathless packages";

   my $code;

   while() {
      $code = sql_fetch DBH, "select code from pkg where id = ? and ctime = ?", $self->{path}, $self->{ctime};
      last if $code;
      $self->unload;
      $self->load_config;
   }

   $code or fancydie "load_config: unable to compile package", $self->{path};
   $code = Storable::thaw $code;

   local $PApp::papp = $self;

   $self->for_all_packages(sub {
      my ($ppkg, $path, $name) = @_;
      my $code = $code->{"$path/$name"}
         or fancydie "config/code disagree", "no code for package $path/$name found";

      $ppkg->compile($code);

      # add cb's from current package
      for my $type (qw(init childinit childexit request cleanup newsession newuser)) {
         push @{$self->{cb_src}{$type}}, map "package $ppkg->{package};\n$_", @{$code->{cb}{$type}};
      }
   });

   for my $type (qw(init childinit childexit)) {
      my $cb = join ";", PApp::Util::uniq delete $self->{cb_src}{$type};
      $self->{cb}{$type} = eval "use utf8; no bytes; sub {\n$cb\n}";
      fancydie "error while compiling application callback", $@,
               info => [name => $self->{name}],
               info => [path => $self->{path}],
               info => [source => $self->{cb_src}{$type}] if $@;
   }

   $self->{compiled} = 1;

   $self;
}

=item $ppkg->for_all_packages (callback<papp,path,name>, initial-path)

Run a sub for all packages in a papp.

=cut

sub for_all_packages($&;$$) {
   my $self = shift;
   my $cb   = shift;
   my $path = shift || "";

   $self->{root}->for_all_packages($cb, $path, $self->{root}{name});
}

sub unload {
   my $self = shift;

   # this is most important
   sql_exec DBH, "delete from pkg where id = ? and ctime = ?", $self->{path}, $self->{ctime};

   delete $self->{cb_src};
   delete $self->{cb};

   delete $self->{ctime};
   delete $self->{compiled};
   delete $self->{translate};
   delete $self->{file};
   delete $self->{root}; # this might trigger a lot of memory freeing!
}

=item $papp->event("event")

Distributes the event to all subpackages/submodules.

=cut

sub event($$) {
   my $self = shift;
   my $event = shift;
   if ($self->{cb}{$event}) {
      $self->{cb}{$event}();
      delete $self->{cb}{$event} if $event eq "init";
   }
}

=item $papp->load

Make sure the application is loaded (i.e. in-memory)

=cut

sub load {
   my $self = shift;

   $self->load_code;
}

=item $papp->surl(surl-args)

=item $papp->slink(slink-args)

Just like PApp::surl and PApp::slink, except that it also jumps into the
application (i.e. it switches applications).  C<surl> will act as if you
were in the main module of the application.

=cut

sub surl {
   my $self = shift;

   package PApp;
   local $modules = {};
   local $curmod = \$modules;
   local $curpath = "";
   local $curprfx = "/$self->{name}";
   local $module  = "";
   push @_, "/papp_appid" => $self->{appid};
   &PApp::surl;
}

sub slink {
   my $content = splice @_, 1,1;
   PApp::alink($content, &surl);
}

# the next var should be part of PApp::papp_main#FIXME#
my %import;

sub find_import($) {
   my $path = shift;
   my $imp = $import{$path};
   unless (defined $imp) {
      $imp = new PApp::Application path => $path;
      $imp->load_config;
      $imp->check_deps;
      $import{$path} = $imp;
   }
   $imp;
}

=item $changed = $papp->check_deps

Check dependencies and unload application if any dependencies have
changed.

=cut

sub check_deps($) {
   my $self = shift;
   my $reload;

   # special request of janman, maybe take it out because too slow and
   # unneeded?
   $self->{compiled} && $self->for_all_packages(sub {
      my ($ppkg) = @_;

      for my $imp (@import{keys %{$ppkg->{import}}}) {
         $reload += $imp->check_deps;
      }
   });

   while (my ($path, $v) = each %{$self->{file}}) {
      $reload++ if (stat $path)[9] > $v->{mtime};
   }

   $self->reload if $reload;
   $reload;
}

sub reload {
   my $self = shift;
   my $code = $self->{compiled};
   warn "reloading application $self->{name}";
   $self->unload;
   $self->load_config;
   $self->load_code if $code;
}

=item register_file($name, %attrs)

Register an additional file (for dependency tracking and i18n
scanning). There should never be a need to use this function. Example:

  $papp->register_file("/etc/issue", lang => "en", domain => "mydomain");

=cut

sub register_file {
   my $self = shift;
   my $name = shift;
   my %attr = @_;
   $attr{lang} = PApp::I18n::normalize_langid $attr{lang};
   $self->{file}{$name} = \%attr;
}

=item %files = $papp->files([include-imports])

Return a hash of C<path> => { info... } pairs delivering information about
all files of the application. If C<include-imports> is true, also includes
all files form imports.

=cut

sub files($;$) {
   my $self = shift;
   my $imports = shift;

   $self->load_config;

   my %res = %{$self->{file}};

   if ($imports) {
      $self->for_all_packages(sub {
         my ($ppkg) = @_;

         for $imp (map PApp::Application::find_import($_), keys %{$ppkg->{import}}) {
            $imp->load_config;
            %res = (%res, $imp->files(1));
         }
      });
   }

   %res;
}

=item $papp->run

"Run" the application, i.e. find the current package & module and execute it.

=cut

sub run {
   package PApp;

   local $papp    = shift;
   local $curpath = "";
   local $curprfx = "/$papp->{name}";

   local $PApp::SQL::Database;
   local $PApp::SQL::DBH;

   if ($papp->{database}) {
      $PApp::SQL::Database = $papp->{database};
      $PApp::SQL::DBH =
         $PApp::SQL::Database->checked_dbh
            or fancydie "error connecting to database ".$PApp::SQL::Database->dsn, $DBI::errstr;
   }

   $papp->{root}->run(\$modules);
}

=item $papp->new_package(same arguments as PApp::Package->new)

Creates a new PApp::Package that belongs to this application.

=cut

sub new_package {
   my $self = shift;
   my $ppkg = new PApp::Package(@_);
   Convert::Scalar::weaken ($ppkg->{papp} = $self);
   $ppkg;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

