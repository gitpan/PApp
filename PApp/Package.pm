##########################################################################
## All portions of this code are copyright (c) 2003,2004 nethype GmbH   ##
##########################################################################
## Using, reading, modifying or copying this code requires a LICENSE    ##
## from nethype GmbH, Franz-Werfel-Str. 11, 74078 Heilbronn,            ##
## Germany. If you happen to have questions, feel free to contact us at ##
## license@nethype.de.                                                  ##
##########################################################################

=head1 NAME

PApp::Package - Application Package Class.

=head1 SYNOPSIS

=head1 DESCRIPTION

Every application in PApp is represented as a PApp::Package (currently
this also defines a unique namespace). This Module defines
the C<PApp::Package> and C<PApp::Module> classes.

=over 4

=cut

$VERSION = 1;

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

   while (my ($name, $ppkg) = each %{$ppkg->{pkg}}) {
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

   my $uri = PApp::Util::find_file $path, [qw(pxslt xslt pxsl xsl pxml xml)]
      or fancydie "stylesheet file not found", $path;

   $type ||= "xml" if $uri =~ /\.x[ms]lt?$/i;

   if ($PApp::papp) {
      # register this file in the current application
      $PApp::papp->register_file($uri,
           mtime  => (stat $uri)[9],
           domain => $domain,
           lang   => $lang,
      );
   }

   my $xsl = PApp::Util::fetch_uri($uri);

   PApp::XML::xml2utf8($xsl);

   require PApp::PCode;
   $xsl = PApp::PCode::pxml2pcode($xsl) if $type ne "xml";
   $xsl = PApp::XML::xml_include($xsl, $uri) if $xsl =~ m%http://www.w3.org/1999/XML/xinclude%;
   $xsl = PApp::PCode::pcode2pxml($xsl) if $type ne "xml";

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
      local $SIG{__DIE__} = \&PApp::Exception::diehandler;
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
      local $SIG{__DIE__} = \&PApp::Exception::diehandler;
      my $data = "<papp:module xmlns:papp='$PApp::xmlnspapp' package='$ppkg->{name}' module='$name'>$_[3]</papp:module>";
      $xslt->apply_string($data);
   } or do {
      return "" unless $@; # error, 0 might also be returned as ""
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
   my $lexical = '$PAPP_'.++$lexname;
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
   $data = "#line 1 \"(compile preamble)\"\n".
           "#".(join ":", caller)."\n".
           "package $ppkg->{package}; use utf8; no bytes;\n".
           "{\n$ppkg->{header};\n$data\n}\n";
   local $SIG{__DIE__} = \&PApp::Exception::diehandler;
   $sub = eval $data;

   $@ and PApp::Exception::fancydie "error while compiling into $ppkg->{package}:",
                                    $@, info => [source => PApp::Util::format_source($data)];

   $sub;
}

my $upid = "PPKG0000";

# locked just to be on the safe side
sub compile : locked {
   my $ppkg = shift;
   my $code = shift;

   $ppkg->{package} and fancydie "compile called on a ppkg with a defined package";

   if ($ppkg->{name} =~ /::/) {
      $ppkg->{package} = $ppkg->{name};
   } else {
      $ppkg->{package} = "PApp::".++$upid,
   }

   local $PApp::ppkg          = $ppkg;
   local $PApp::SQL::Database = $PApp::SQL::Database;
   local $PApp::SQL::DBH      = $PApp::SQL::DBH;

   if ($ppkg->{database}) {
      $PApp::SQL::Database = $ppkg->{database};
      $PApp::SQL::DBH      =
         $PApp::SQL::Database->checked_dbh
            or fancydie "error connecting to database ".$PApp::SQL::Database->dsn, $DBI::errstr;
   }

   *{$ppkg->{package}."::EXPORT"} = $ppkg->{export};
   @{$ppkg->{package}."::ISA"} = q(PApp::Package);

   my $translator = PApp::I18n::open_translator(
                       "$PApp::i18ndir/$ppkg->{domain}",
                       @{$ppkg->{langs}},
                    );
   
   *{$ppkg->{package}."::papp_translator"} = \$translator;
   ${$ppkg->{package}."::papp_ppkg"      } = $ppkg;
   *{$ppkg->{package}."::papp_ppkg_table"} = sub { PApp::I18n::get_table($translator, $PApp::langs) };
   
   *{$ppkg->{package}."::__"}      = sub ($) { PApp::I18n::Table::gettext(PApp::I18n::get_table($translator, $PApp::langs), $_[0]) };
   *{$ppkg->{package}."::gettext"} = sub ($) { PApp::I18n::Table::gettext(PApp::I18n::get_table($translator, $PApp::langs), $_[0]) };

   my $body = "
#line 1 \"(module preamble '$ppkg->{name}')\"
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

   $ppkg->_eval(
      $body .
      "# body '$ppkg->{name}'\n" . $code->{body} .
      "\n#line 1 \"(module postamble '$ppkg->{name}')\""
   );

   for my $type (qw(request cleanup newuser newsession)) {
      my $cb = join ";\n", PApp::Util::uniq @{ $code->{cb}{$type} };
      $ppkg->{cb}{$type} = $ppkg->_eval("sub { $cb }");
   }

   while (my ($k, $v) = each %{$code->{module}}) {
      $ppkg->{module}{$k}{cb} = $ppkg->_eval("# module '$k'\nsub {\n$v\n}");
   }

   delete $ppkg->{lexical}; # save some memory and also keep the rfeerence counters sane
}

sub mark_statekey {
   my ($ppkg, $key, $attr, $extra) = @_;
   $ppkg->{preferences}{$key}   = 1 if $attr eq "preferences";
   $ppkg->{import_key}{$key}    = 1 if $attr eq "import";
   $ppkg->{local}{$key}{$extra} = 1 if $attr eq "local";
}

=item $ppkg->insert($name, $module, $conf) *EXPERIMENTAL*

Insert the given package at the current position, optionally setting the
default module to C<$module> and C<$PApp::curconf> to C<$conf>. If no name
is given (or $name is undef), the package will be embedded under it's
"natural" name, otherwise the given name is used to differentiate between
different instances of the same package.

The PApp namespace (i.e. <%S> and <%A>) will be shared with the inserted
package.

You can (currently) access packages embedded in another module using the
$ppkg->{pkg}{packagename} syntax.

This API might not be stable.

=cut

sub insert($;$$$) {
   package PApp;

   my $ppkg = shift;
   my $name = shift || $ppkg->{name};
   my $module = shift;
   my $conf = shift;

   local (%S, %A);

   local $curconf = $conf;
   #ocal $curprfx = $curprfx; # 'tis correct
   local $curpath = "$curpath/$name";

   $$curmod->{$name}{"\x00"} ||= $module;
   PApp::Package::run($ppkg, \$$curmod->{$name});
}

=item $ppkg->embed($name, $module, $conf) *EXPERIMENTAL*

Embed the given package. This function is identical to the insert method
above with the exception of the namespace (eg. %S) , which will NOT be
shared with the embedding package.

You can (currently) access packages embedded in another module using the
$ppkg->{pkg}{packagename} syntax.

This API might not be stable.

=cut

sub embed($;$$$) {
   package PApp;

   my $ppkg = shift;
   my $name = shift || $ppkg->{name};
   my $module = shift;
   my $conf = shift;

   local (%S, %A);

   local $curconf = $conf;
   local $curprfx = "$curprfx/$name";
   local $curpath = "$curpath/$name";

   $$curmod->{$name}{"\x00"} ||= $module;
   PApp::Package::run($ppkg, \$$curmod->{$name});
}

sub run($$) {
   package PApp;

   local $ppkg   = shift;
   local $curmod = shift;

   local $module = $$curmod->{"\x00"};
   local $pmod = $ppkg->{module}{$module} || $ppkg->{module}{"*"};

   $pmod or fancydie "no such module", "'$module'",
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

   # TODO: key on $transactions not on $state
   if (exists $state{$curprfx}) {
      *S = $state       {$curprfx};
      *A = $arguments   {$curprfx};
   } else {
      *S = $state       {$curprfx}   = {};
      *A = $arguments   {$curprfx} ||= {};

      while (defined $pmod->{nosession}) {
         $module = $$curmod->{"\x00"} = $pmod->{nosession};
         $pmod = $ppkg->{module}{$module};
      }

      unless (load_prefs($curprfx)) {
         push @{$state{papp_execonce}}, $save_prefs_cb;
         $ppkg->{cb}{newuser}();
      }

      $ppkg->{cb}{newsession}();
   }

   # nuke local variables that are not defined locally...
   while (my ($k, $v) = each %{$ppkg->{local}}) {
      delete $S{$k} unless exists $v->{$module};
   }

   # enter any parameters deemed safe (import parameters);
   for (keys %{$ppkg->{import_key}}) {
      $S{$_} = delete $P{$_} if exists $P{$_};
   }

   #while (my ($k, $v) = each %P) {
   #   $S{$k} = $v if $submod->{import_key}{$k};
   #}

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

