=head1 NAME

PApp::Package - Application Package Class.

=head1 SYNOPSIS

=head1 DESCRIPTION

Every application in PApp is represented as a PApp::Package (currently
this also defines a unique namespace). This Module defines
the C<PApp::Package> and C<PApp::Module> classes.

=over 4

=cut

$VERSION = 0.12;

package PApp::Package;

use base 'Exporter';

use Symbol ();

use Storable ();

use PApp::Exception;
use PApp::PCode;
use PApp::Util;
use PApp::SQL;

sub new {
   my $class = shift;
   bless {
#      import => {},
#      cb_src => {
#                   #init       => "",
#                   #childinit  => "",
#                   #childexit  => "",
#                   #request    => "",
#                   #cleanup    => "",
#                   #newsession => "",
#                   #newuser    => "",
#                   #body       => "",
#                },
#      lang   => {},
#      i18ndir=> $PApp::i18ndir,
#      modules=> [ '' ],
      @_,
   }, $class;
}

=item $ppkg->config([key])

Returns a hash-ref (no options) with the current configuration
information, or a specific configuration value for the current
application.

Examples:

 my $path = $ppkg->config("path");

 my $cfg = $ppkg->config;
 my $path = $cfg{path};

=cut

sub config {
   my $self = shift;
   @_ ? $PApp::curconf->{$_[0]} : $PApp::curconf;
}

=item $ppkg->for_all_modules (callback<pmod,path,name>, initial-path)

Run a sub for all modules of a ppkg.

=cut

# run a sub for all submodules of a pmod
sub for_all_modules($&;$) {
   my ($ppkg, $cb, $path, $name) = @_;

   die;
   $cb->($ppkg, $path, $name);

   $path .= $name;

   while (my ($ppkg, $pmod) = each %$pmod) {
      next unless $name =~ /^\//;
      $pmod->for_all_modules($cb, $path, $name);
   }
}

=item $ppkg->for_all_packages (callback<papp,path,name>, initial-path)

Run a sub for all packages in a papp.

=cut

sub for_all_packages($&;$$) {
   my $ppkg = shift;
   my $cb   = shift;
   my $path = shift;
   my $name = shift || $ppkg->{name};

   $cb->($ppkg, $path, $name);

   $path .= "/$name";

   while (my ($name, $ppkg) = each %{$ppkg->{embed}}) {
      $ppkg->for_all_packages($cb, $path, $name);
   }
}

=item $ppkg->load_stylesheet($path, [$type, [$domain, $lang]])

Load a PApp::XSLT stylesheet of type $type (either C<pxml> (default unless
guessed by the extension) or C<xml> and language C<$lang> into the package
and return it. It is planned to do some caching in the future.

=cut

sub load_stylesheet {
   my ($self, $path, $type, $domain, $lang) = @_;

   require PApp::XML;
   require PApp::PCode;

   my $xsl = PApp::Config::find_file $path, qw(pxslt xslt pxsl xsl pxml xml)
      or fancydie "stylesheet file not found", $path;

   $type ||= "xml" if $xsl =~ /\.x[ms]lt?$/;

   if ($PApp::papp) {
      # register this file in the current application
      $PApp::papp->register_file($xsl,
           mtime  => (stat $xsl)[9],
           domain => $domain,
           lang   => $lang,
      );
   }

   $xsl = do { local (*X, $/); open X, "<", $xsl or fancydie "$xsl: $!"; <X> };
   PApp::XML::xml2utf8($xsl);

   require PApp::XSLT;
   my $xslt = PApp::XSLT->new(stylesheet => "data:,$xsl");

   $self->compile_xslt($xslt) if $type ne "xml";

   $xslt;
}

sub compile_xslt {
   my $self = shift;
   my $xslt = shift;

   my $xsl = $xslt->stylesheet;
   my $pxml = PApp::PCode::pxml2pcode($xsl);

   # eval=onload
   eval {
      local $SIG{__DIE__};
      $pxml = $self->_eval(
            "sub { PApp::capture (sub { package $self->{package};"
            . PApp::PCode::pcode2perl($pxml) .
         " }) }"
      );
   };
   if ($@) {
      my $error = $@;
      $xsl = PApp::Util::format_source($xsl);
      fancydie "stylesheet evaluation error", $error, info => $xsl;
   }
   $xslt->stylesheet($pxml);
}

sub xslt_transform {
   my $ppkg = $_[0];
   my $name = $_[1];
   my $xslt = $_[2];
   eval {
      local $SIG{__DIE__};
      my $data = "<papp:module xmlns:papp='$PApp::xmlnspapp' package='$ppkg->{name}' module='$name'>$_[3]</papp:module>";
      $xslt->apply_string($data);
   } or do {
      return "" unless $@; # error, "0" also is returned as ""
      PApp::Exception::fancydie "error while applying stylesheet to $ppkg->{name}/$name:", $@,
                                info => [ "Page Source" => PApp::Util::format_source $_[3] ];
   };
}

sub DESTROY {
   my $self = shift;

   # try to get rid of the package
   Symbol::delete_package($self->{package}) if $self->{package};
}

=item $ppkg->refer('callback', [ARGS...]);

This method C<refer>'s a callback (see PApp::Callback::refer) defined
using the callback element on the package level and returns the resulting
coderef.

=cut

sub refer($$;@) {
   my $self = shift;
   my $name = shift;

   $self->{callback}{$name}->refer(@_);
}

=item $ppkg->gen_lexical($value)

(internal). Generate a new lexical to be used in compilation and return
it's name (including '$').

=cut

my $lexname = "a000000";

sub gen_lexical : locked {
   my $self = shift;
   my $value = shift;
   push @{$self->{lexical}}, $value;
   my $lexical = '$PAPP_PACKAGE_LEXICAL_'.++$lexname;
   $self->{header} .= "my $lexical = \$PApp::ppkg->{lexical}[".scalar($#{$self->{lexical}})."];\n";
   $lexical;
}

sub _eval : locked {
   package PApp;

   local $ppkg = shift;
   local $data = shift;

   $ppkg->{package} or fancydie "_eval called but no package allocated";#d##FIXME#
   
   # be careful not to use "my" for global variables -> my vars
   # are visible within the subs we create!
   $data = "#".(join ":", caller)."\n".
           "package $ppkg->{package}; use utf8; no bytes;\n".
           "{\n$ppkg->{header};\n$data\n}\n";
   local $SIG{__DIE__};
   $sub = eval $data;

   $@ and
      PApp::Exception::fancydie "Error while compiling into $ppkg->{package}:",
                                $@, info => [source => PApp::Util::format_source($data)];

   $sub;
}

my $upid = "PPKG0000";

# locked just to be on the safe side
sub compile : locked {
   my $ppkg = shift;
   my $code = shift;

   $ppkg->{package} and fancydie "compile called on a ppkg with a defined package";
   $ppkg->{package} = "PApp::".++$upid,

   local $PApp::ppkg = $ppkg;
                         # ¿dead?
   #local $PApp::output; # bodies can generate spurious output

   *{$ppkg->{package}."::EXPORT"} = $ppkg->{export};
   @{$ppkg->{package}."::ISA"} = q(PApp::Package);
   
   *{$ppkg->{package}."::papp_ppkg_table"} = \my $ppkg_table;
   ${$ppkg->{package}."::papp_translator"} = PApp::I18n::open_translator(
                                                "$PApp::i18ndir/$ppkg->{domain}",
                                                @{$ppkg->{langs}},
                                             );
   *{$ppkg->{package}."::__"}              = sub ($) { PApp::I18n::Table::gettext($ppkg_table, $_[0]) };
   *{$ppkg->{package}."::gettext"}         = sub ($) { PApp::I18n::Table::gettext($ppkg_table, $_[0]) };

   push @{$code->{cb}{request}}, "
#line 1 \"(language initialization '$ppkg->{name}')\"
package $ppkg->{package};
\$papp_ppkg_table = PApp::I18n::get_table(\$papp_translator, \$PApp::langs);
";

   my $body = "
# every module starts like this (lots of goodies pre-imported)
use PApp;
use PApp::Config ();
use PApp::SQL;
use PApp::HTML;
use PApp::Exception;
use PApp::Callback;
use PApp::Env;
use PApp::Util (); # nothing yet

";

   for $imp (map PApp::Application::find_import($_), keys %{$ppkg->{import}}) {
      $imp->load_code;

   #FIXME#
      #if ($attr{export} eq "yes") {
            #push @{$ppkg->{export}}, @{$imp->{export}};
      #}

      $body .= "# import $imp->{path}\nBEGIN { import $imp->{root}{package} }\n\n";

      for my $type (qw(request cleanup newuser newsession)) {
         push @{$code->{cb}{$type}}, @{$imp->{cb_src}{$type}};
      }
   }
   delete $ppkg->{import} unless $PApp::checkdeps;

   $ppkg->_eval($body . "# body '$ppkg->{name}'\n" . $code->{body});

   for my $type (qw(request cleanup newuser newsession)) {
      my $cb = join ";\n", PApp::Util::uniq $code->{cb}{$type};
      $ppkg->{cb}{$type} = $ppkg->_eval("sub { $cb }");
   }

   while (my ($k, $v) = each %{$code->{module}}) {
      $ppkg->{module}{$k}{cb} = $ppkg->_eval("# module '$k'\nsub {\n$v\n}");
   }
}

sub mark_statekey {
   my ($ppkg, $key, $attr, $extra) = @_;
   $ppkg->{preferences}{$key}   = 1 if $attr eq "preferences";
   $ppkg->{import_key}{$key}    = 1 if $attr eq "import";
   $ppkg->{local}{$key}{$extra} = 1 if $attr eq "local";
}

sub insert($$;$) {
   package PApp;

   my $ppkg = shift;
   my $name = shift;
   my $conf = shift;

   $ppkg = $ppkg->{embed}{$name}
      or fancydie "embed: no such package in $ppkg->{name}", $name;
   
   local (%S, %A);

   local $curconf = $conf;
   #ocal $curprfx = $curprfx;
   local $curpath = "$curpath/$name";

   PApp::Package::run($ppkg, \($$curmod->{$name} ||= { "\x00" => "" }) );
}

sub embed($$;$) {
   package PApp;

   my $ppkg = shift;
   my $name = shift;
   my $conf = shift;

   $ppkg = $ppkg->{embed}{$name}
      or fancydie "embed: no such package in $ppkg->{name}", $name;
   
   local (%S, %A);

   local $curconf = $conf;
   local $curprfx = "$curprfx/$name";
   local $curpath = "$curpath/$name";

   PApp::Package::run($ppkg, \($$curmod->{$name} ||= { "\x00" => "" }) );
}

sub run($$) {
   package PApp;

   local $ppkg   = shift;
   local $curmod = shift;

   local $module = $$curmod->{"\x00"};
   local $pmod = $ppkg->{module}{$module};

   $pmod->{cb} or fancydie "no such module", "'$module'",
                           info => [curpath => $curpath],
                           info => ["valid modules include" => join "\n", keys %{$ppkg->{module}}],
                          ;

   local $PApp::surlstyle     = $ppkg->{surlstyle};

   # the following locals should be faster
   local $PApp::SQL::Database = $PApp::SQL::Database;
   local $PApp::SQL::DBH      = $PApp::SQL::DBH;

   if ($ppkg->{database}) {
      $PApp::SQL::Database = $ppkg->{database};
      $PApp::SQL::DBH =
         $PApp::SQL::Database->checked_dbh
            or fancydie "error connecting to database ".$PApp::SQL::Database->dsn, $DBI::errstr;
   }

   if (exists $state{$curprfx}) {
      *S = $state    {$curprfx};
      *A = $arguments{$curprfx};
      *T = $arguments{$curprfx};
   } else {
      *S = $state    {$curprfx} = {};
      *A = $arguments{$curprfx} = {};
      *T = $arguments{$curprfx} = {};

      while (defined $pmod->{nosession}) {
         $pmod = $ppkg->{module}{$pmod->{nosession}};
      }

      $ppkg->{cb}{newsession}();

      unless (PApp::load_prefs($curprfx)) {
         push @{$state{papp_execonce}}, $save_prefs_cb;
         $ppkg->{cb}{newuser}();
      }
   }

   # nuke local variables that are not defined locally...
   while (my ($k, $v) = each %{$ppkg->{local}}) {
      delete $S{$k} unless exists $v->{$module};
   }

   for (keys %{$ppkg->{import_key}}) {
      $S{$_} = delete $P{$_} if exists $P{$_};
   }

   # enter any parameters deemed safe (import parameters);
   while (my ($k, $v) = each %P) {
      $S{$k} = $v if $submod->{import_key}{$k};
   }

   # WE ARE INITIALIZED
      
   $ppkg->{cb}{request}();
   $pmod->{cb}();
   $ppkg->{cb}{cleanup}();
}

sub set_database($$) {
   my $self = shift;
   my $database = shift;
   $self->{database} = $database;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

