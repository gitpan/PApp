#if (!defined $PApp::_compiled) { eval do { local $/; <DATA> }; die if $@ } 1;
#__DATA__

#line 5 "(PApp.pm)"

=head1 NAME

PApp - multi-page-state-preserving web applications

=head1 SYNOPSIS

 * This module requires quite an elaborate setup (see the INSTALL file). *
 * Please read the LICENSE file (PApp is neither GPL nor BSD licensed).  *

=head1 DESCRIPTION

PApp is a complete solution for developing multi-page web
applications that preserve state I<across> page views. It also tracks user
id's, supports a user access system and provides many utility functions
(html, sql...). You do not need (and should not use) the CGI module.

Advantages:

=over 4

=item * Speed. PApp isn't much slower than a hand-coded mod_perl handler,
and this is only due to the extra database request to fetch and restore
state, which typically you would do anyway. To the contrary: a non-trivial
Apache::Registry page is slower than the equivalent PApp application (or
much, much more complicated); Note: as of version 0.10, this is no longer
true, but I am working on it ;) It is, however, much easier to use than
anything else (while still not being slow).

=item * Embedded Perl. You can freely embed perl into your documents. In
fact, You can do things like these:

   <h1>Names and amounts</h1>
   <:
      my $st = sql_exec \my($name, $amount), "select name, amount from ...",

      while ($st->fetch) {?>
         Name: $name, Amount: $amount<p>
      <:}
   :>
   <hr>

That is, mixing html and perl at statement boundaries.

=item * State-preserving: The global hash C<%S> is automaticaly
preserved during the session. Everything you save there will be available
in any subsequent pages that the user accesses.

=item * XML. PApp-applications are written in XML. While this is no
advantage in itself, it means that it uses a standardized file format that
can easily be extended. PApp comes with a DTD and a vim syntax
file, even ;)

=item * Easy internationalization. I18n has never been that easy:
just mark you strings with __C<>"string", either in html or in the perl
source. The "poedit"-demo-application enables editing of the strings
on-line, so translaters need not touch any text files and can work
diretcly via the web.

=item Feature-Rich. PApp comes with a I<lot> of
small-but-nice-to-have functionality.

=back

Disadvantages:

=over 4

=item * Unfinished Interface: To admit it, this module is young and many
features have a kind-of-unfinished interface. PApp will certainly be
changed and improved to accomodate new features (like CGI-only operation).

=item * No documentation. Especially tutorials are missing, so you are
most probably on your own.

=item * Perl5.7.0 is required (actually, a non-released bugfixed version
of 5.7). While not originally an disadvantage in my eyes, Randal Schwartz
asked me to provide some explanation on why this is so (at the time I only
required 5.6):

"As for an explanation, I require perl5.6 because I require a whole
lot of features of 5.6 (e.g. DB.pm, utf-8 support, "our", bugfixes,
3-argument open, regex improvements, probably many others, especially
changes on the XS level). In the future it will likely require weak
references, filehandle autovivification, the XSLoader for extra speed in
rare circumstances... I don't want to backport this to older versions ;)"

=back

Be advised that, IF YOU WANT TO USE THIS MODULE, PELASE DROP THE AUTHOR
(Marc Lehmann <pcg@goof.com>) A MAIL. HE WILL HELP YOU GETTING STARTED.

To get a quick start, read the bench.papp module, the dbedit.papp module,
the cluster.papp module and the papp.dtd description of the papp file
format.

=cut

package PApp;

use 5.006;

use utf8;
no bytes;

#   imports
use Carp;
use FileHandle ();
use File::Basename qw(dirname);

use Storable;

use Compress::LZF;
use Crypt::Twofish2;

use PApp::Config qw($DBH DBH);
use PApp::FormBuffer;
use PApp::Exception;
use PApp::I18n;
use PApp::HTML;
use PApp::SQL;
use PApp::Callback;
use PApp::Application;
use PApp::Package;
use PApp::Util;
use PApp::Recode ();

<<' */'=~m>>;
 
/*
 * the DataRef module must be included just in case
 * no application has been loaded and we need to deserialize state,
 * since overloaded packages must alread exist before an object becomes
 * overloaded. Ugly.
 */

use PApp::DataRef ();

use Convert::Scalar qw(:utf8 weaken);

BEGIN {
   $VERSION = 0.12;

   use base Exporter;

   @EXPORT = qw(
         debugbox

         surl slink sform cform suburl sublink retlink_p returl retlink
         current_locals reference_url multipart_form parse_multipart_form
         endform redirect internal_redirect abort_to content_type abort_with

         SURL_PUSH SURL_UNSHIFT SURL_POP SURL_SHIFT
         SURL_EXEC SURL_SAVE_PREFS SURL_SET_LANG SURL_SUFFIX

         surl_style
         SURL_STYLE_URL SURL_STYLE_GET SURL_STYLE_STATIC

         $request $NOW *ppkg $papp *state %P *A *S *L *T
         $userid $sessionid reload_p switch_userid save_prefs

         dprintf dprint echo capture $request 
         
         N_ language_selector
   );
   @EXPORT_OK = qw(config_eval abort_with_file);

   require XSLoader;
   XSLoader::load 'PApp', $VERSION;

   unshift @ISA, PApp::Base;
}

#   globals
#   due to what I call bugs in mod_perl, my variables do not survive
#   configuration time unless global

    $translator;

    $configured;

    $key          = $PApp::Config{CIPHERKEY};
our $cipher_e;
    $cipher_d;

    $libdir       = $PApp::Config{LIBDIR};
    $i18ndir      = $PApp::Config{I18NDIR};

our $stateid;     # uncrypted state-id
    $sessionid;
    $prevstateid;
    $alternative;

our $userid;      # uncrypted user-id

our %state;
our %arguments;
our %transactions;
our %S; # points into %state
our %A; # points into %arguments
our %T; # points into %transactions
our %P;

our %papp;        # toplevel ("mounted") applications

our $NOW;         # the current time (so you only need to call "time" once)

# other globals. must be globals since they should be accessible outside
our $output;      # the collected output (must be global)
our $routput = \$output; # the real output, even inside capture {}
our $doutput;     # debugging output
our $location;    # the current location (a.k.a. application, pathname)
our $pathinfo;    # the "CGI"-pathinfo
our $papp;        # the current location (a.k.a. application)

our $modules;     # the module state
our $module;      # the current module name (single component)
our $curprfx;     # the current state prefix
our $curpath;     # the current application/package path
our $curmod;      # the current module (ref into $modules)#d##FIXME#
our $ppkg;        # the current package (a.k.a. package)
our $curconf;     # the current configuration hash

our $request;     # the apache request object

our %module;      # module path => current module

our @pmod;        # the current stack of pmod's NYI

our $langs;       # contains the current requested languages (e.g. "de, en-GB")

    $cookie_reset   = 86400;       # reset the cookie at most every ... seconds
    $cookie_expires = 86400 * 365; # cookie expiry time (one year, whooo..)

    $checkdeps;   # check dependencies (relatively slow)
    $delayed;     # delay loading of apps until needed

our %preferences; # keys that are preferences are marked here

    $content_type;
    $output_charset;
our $output_p = 0;# flush called already?

    $surlstyle  = scalar SURL_STYLE_URL;

    $in_cleanup = 0;  # are we in a clean-up phase?

    $onerr      = 'sha';

our $url_prefix_nossl = undef;
our $url_prefix_ssl = undef;
our $url_prefix_sslauth = undef;

our $logfile = undef;

%preferences = (  # system default preferences
   '' => [qw(
      lang
      papp_visits
      papp_last_cookie
   )],
);

our $papp_main;

our $restart_flag;
if ($restart_flag) {
   die "FATAL ERROR: PerlFreshRestart is buggy\n";
   PApp::Util::_exit(0);
} else {
   $restart_flag = 1;
}

my $save_prefs_cb = create_callback {
   &save_prefs if $userid;
} name => "papp_save_prefs";

sub SURL_PUSH         (){ ( "\x00\x01", undef ) }
sub SURL_UNSHIFT      (){ ( "\x00\x02", undef ) }
sub SURL_POP          (){ ( "\x00\x81" ) }
sub SURL_SHIFT        (){ ( "\x00\x82" ) }
sub SURL_EXEC         (){ ( SURL_PUSH, "/papp_execonce" ) }
sub SURL_SAVE_PREFS   (){ ( SURL_EXEC, $save_prefs_cb ) }
sub SURL_SET_LANG     (){ ( SURL_SAVE_PREFS, "/lang" ) }

sub SURL_STYLE        (){ "\x00\x41" }
sub _SURL_STYLE_URL   (){ 1 }
sub _SURL_STYLE_GET   (){ 2 }
sub _SURL_STYLE_STATIC(){ 3 }

sub SURL_STYLE_URL    (){ ( SURL_STYLE, _SURL_STYLE_URL    ) }
sub SURL_STYLE_GET    (){ ( SURL_STYLE, _SURL_STYLE_GET    ) }
sub SURL_STYLE_STATIC (){ ( SURL_STYLE, _SURL_STYLE_STATIC ) }

sub SURL_SUFFIX      (){ "\x00\x42" }

sub CHARSET (){ "utf-8" } # the charset used internally by PApp

# we might be slow, but we are rarely called ;)
sub __($) {
   $translator
      ? $translator->get_table($langs)->gettext($_[0])
      : $_[0];
}

sub N_($) { $_[0] }

# constant
our $xmlnspapp = "http://www.plan9.de/xmlns/papp";

=head1 GLOBAL VARIABLES

Some global variables are free to use and even free to change (yes, we
still are about speed, not abstraction). In addition to these variables,
the globs C<*state>, C<*S> and C<*A> (and in future versions C<*L>)
are reserved. This means that you cannot define a scalar, sub, hash,
filehandle or whatsoever with these names.

=over 4

=item $request [read-only]

The Apache request object (L<Apache>), the same as returned by C<Apache->request>.

=item %state [read-write, persistent]

A system-global hash that can be used for almost any purpose, such as
saving (global) preferences values. All keys with prefix C<papp> are
reserved for use by this module. Everything else is yours.

=item %S [read-write, persistent]

Similar to C<%state>, but is local to the current application. Input
arguments prefixed with a dash end up here.

=item %T [read-write, persistent]

(NYI) reserved

=item %L [read-write, persistent]

(NYI) reserved

=item %A [read-write, input only]

A global hash that contains the arguments to the current module. Arguments
to the module can be given to surl or any other function that calls it, by
prefixing parameter names with a minus sign (i.e. "-switch").

=item %P [read-write, input only]

Similar to C<%A>, but it instead contains the parameters from
forms submitted via GET or POST (C<see parse_multipart_form>,
however). Everything in this hash is insecure by nature and must should be
used carefully.

Normally, the values stored in C<%P> are plain strings (in utf-8,
though). However, it is possible to submit the same field multiple times,
in which case the value stored in C<$P{field}> is a reference to an array
with all strings, i.e. if you want to evaluate a form field that might be
submitted multiple times (e.g. checkboxes or multi-select elements) you
must use something like this:

   my @values = ref $P{field} ? @{$P{field}} : $P{field};

=item $userid [read-only]

The current userid. User-Id's are automatically assigned to every incoming
connection, you are encouraged to use them for your own user-databases,
but you mustn't trust them.

=item $sessionid [read-only]

A unique number identifying the current session (not page). You could use
this for transactions or similar purposes.

=item $PApp::papp (a hash-ref) [read-only] [not exported] [might get replaced by a function call]

The current PApp::Applicaiton object (see L<PApp::Application>). The
following keys are user-readable:

 config   the argument to the C<config>option given to C<mount>.

=item $ppkg [read-only] [might get replaced by a function call]

This variable contains the current C<PApp::Package> object (see
L<PApp::Package>). This variable might be replaced by something else, so
watch out. This might or might not be the same as $PApp::ppkg, so best use
$ppkg when using it. Ah, actually it's best to not use it at all.

=item $PApp::location [read-only] [not exported] [might get replaced by a function call]

The location value from C<mount>.

=item $PApp::module [read-only] [not exported] [might get replaced by a function call]

The current module I<within> the application (full path).

=item $NOW [read-only]

Contains the time (as returned by C<time>) at the start of the request.
Highly useful for checking cache time-outs or similar things, as it is
faster to use this variable than to call C<time>.

=back

=head1 FUNCTIONS/METHODS

=over 4

=item PApp->search_path(path...);

Add a directory in where to search for included/imported/"module'd" files.

=item PApp->configure(name => value...);

Configures PApp, must be called once and once only. Most of the
configuration values get their defaults from the secured config file
and/or give defaults for applications.

 pappdb        The (mysql) database to use as papp-database
               (default "DBI:mysql:papp")
 pappdb_user   The username when connecting to the database
 pappdb_pass   The password when connecting to the database
 cipherkey     The Twofish-Key to use (16 binary bytes),
               BIG SECURITY PROBLEM if not set!
               (you can use 'mcookie' from util-linux twice to generate one)
 cookie_reset  delay in seconds after which papp tries to
               re-set the cookie (default: one day)
 cookie_expires time in seconds after which a cookie shall expire
               (default: one year)
 logfile       The path to a file where errors and warnings are being logged
               to (the default is stderr which is connected to the client
               browser on many web-servers)

The following configuration values are used mainly for development:

 checkdeps     when set, papp will check the .papp file dates for
               every request (slow!!) and will reload the app when necessary.
 delayed       do not compile applications at server startup, only on first
               access. This greatly increases memory consumption but ensures
               that the httpd startup works and is faster.
 onerr         can be one or more of the following characters that
               specify how to react to an unhandled exception. (default: 'sha')
               's' save the error into the error table
               'v' view all the information (security problem)
               'h' show the error category only
               'a' give the admin user the ability to log-in/view the error

=item PApp->mount_appset($appset)

Mount all applications in the named application set. Usually used in the httpd.conf file
to mount many applications into the same virtual server etc... Example:

  mount_appset PApp 'default';
               
=item PApp->mount_app($appname)

Can be used to mount a single application.

The following description is no longer valid.

 location[*]   The URI the application is mounted under, must start with "/".
               Currently, no other slashes are allowed in it.
 src[*]        The .papp-file to mount there
 config        Will be available to the application as $papp->{config}
 delayed       see C<PApp->configure>.

 [*] required attributes

=item ($name, $version) = PApp->interface

Return name and version of the interface PApp runs under
(e.g. "PApp::Apache" or "PApp:CGI").

=cut

sub event {
   my $self = shift;
   my $event = shift;
   for $papp (values %{$papp->{"/"}}) {
      $papp->event($event);
   }
}

sub search_path {
   shift;
   goto &PApp::Config::search_path;
}

sub PApp::Base::configure {
   my $self = shift;
   my %a = @_;
   my $caller = caller;

   $configured = 1;

   exists $a{libdir}		and $libdir	= $a{libdir};
   exists $a{pappdb}		and $statedb	= $a{pappdb};
   exists $a{pappdb_user}	and $statedb_user = $a{pappdb_user};
   exists $a{pappdb_pass}	and $statedb_pass = $a{pappdb_pass};
   exists $a{cookie_reset}	and $cookie_reset = $a{cookie_reset};
   exists $a{cookie_expires}	and $cookie_expires = $a{cookie_expires};
   exists $a{cipherkey}		and $key	= $a{cipherkey};
   exists $a{onerr}		and $onerr	= $a{onerr};
   exists $a{url_prefix_nossl}	and $url_prefix_nossl = $a{url_prefix_nossl};
   exists $a{url_prefix_ssl}	and $url_prefix_ssl = $a{url_prefix_ssl};
   exists $a{url_prefix_sslauth} and $url_prefix_sslauth = $a{url_prefix_sslauth};

   exists $a{checkdeps} 	and $checkdeps	= $a{checkdeps};
   exists $a{delayed} 		and $delayed	= $a{delayed};

   exists $a{logfile}		and $logfile	= $a{logfile};

   my $lang = { lang => 'en', domain => 'papp' };
   
   $papp_main = new PApp::Application
      path   => "$libdir/apps/papp.papp",
      name   => "papp_main",
      appid  => 0;

   $papp_main->new_package(
      name      => 'papp',
      domain    => 'papp',
   );

   $papp_main->load_config;

   for (
         "$libdir/macro/admin.papp",
         "$libdir/macro/util.papp",
         "$libdir/macro/editform.papp",
         $INC{"PApp.pm"},
         $INC{"PApp/FormBuffer.pm"},
         $INC{"PApp/I18n.pm"},
         $INC{"PApp/Exception.pm"},
       ) {
      $papp_main->register_file($_, domain => "papp", lang => "en");
   };

   $papp{$papp_main->{appid}} = $papp_main;
}

sub PApp::Base::configured {
   # mod_perl does this to us....
   #$configured and warn "PApp::configured called multiple times\n";

   if ($configured == 1) {
      if (!$key) {
         warn "no cipherkey was specified, this is an insecure configuration";
         $key = "c9381ddf6cfe96f1dacea7e7a86887542d6aaa6476cf5bbf895df0d4f298e741";
      }
      my $key = pack "H*", $key;
      $cipher_d = new Crypt::Twofish2 $key;
      $cipher_e = new Crypt::Twofish2 $key;

      PApp::I18n::set_base($i18ndir);

      $translator = PApp::I18n::open_translator("papp", "en");

      $configured = 2;

      PApp->event('init');
   } elsif ($configured == 0) {
      fancydie "PApp: 'configured' called without preceding 'configure'";
   }
}

sub configured_p {
   $configured;
}

#############################################################################

=item dprintf "format", value...
dprint value...

Work just like print/printf, except that the output is queued for later use by the C<debugbox> function.

=item echo value[, value...]

Works just like the C<print> function, except that it is faster for generating output.

=item capture { code/macros/html }

Captures the output of "code/macros/perl" and returns it, instead of
sending it to the browser. This is more powerful than it sounds, for
example, this works:

 <:
    my $output = capture {

       print "of course, this is easy\n";
       echo "this as well";
       :>
          
       Yes, this is captured as well!
       <:&this_works:>
       <?$captureme:>

       <:

    }; # close the capture
 :>

=cut

sub echo(@) {
   $output .= join "", @_;
}

sub capture(&) {
   local *output;
   &{$_[0]};
   $output;
}

sub dprintf(@) {
   my $format = shift;
   $doutput .= sprintf $format, @_;
}

sub dprint(@) {
   $doutput .= join "", @_;
}

=item content_type $type [, $charset]

Sets the output content type to C<$type>. The content-type should be a
registered MIME type (see RFC 2046) like C<text/html> or C<image/png>. The
optional argument C<$charset> can be either "*", which selects a suitable
output encoding dynamically or the name of a registered character set (STD
2). The special value C<undef> suppresses output character conversion
entirely. If not given, the previous value will be unchanged (the default;
is currently "*").

The following is not yet implemented:

The charset argument might also be an array-reference giving charsets that
should be tried in order (similar to the language preferences). The last
charset will be I<forced>, i.e. characters not representable in the output
will be replaced by some implementation defined way (if possible, this
will be C<&#charcode;>, which is as good a replacement as any other ;)

How this interacts with Accept-Charset is still an open issue (for
non-microsoft browsers that actually generate this header ;)

=cut

sub content_type($;$) {
   $content_type = shift;
   $output_charset = shift if @_;
}

=item reference_url $fullurl

Return a url suitable for external referencing of the current
page. If C<$fullurl> is given, a full url (including a protocol
specifier) is generated. Otherwise a partial uri is returned (without
http://host:port/).

This is only a bona-fide attempt: The current module must support starting
a new session and only "import"-variables and input parameters are
preserved.

=cut

sub reference_url {
   my $url;
   return "&lt;reference url not yet implemented&gt;";
   die;
   #FIXME#
   if ($_[0]) {
      $url = "http://" . $request->hostname;
      $url .= ":" . $request->get_server_port if $request->get_server_port != 80;
   }
   my $get = join "&amp;", (map {
                escape_uri($_) . (defined $S{$_} ? "=" . escape_uri $S{$_} : "");
             } grep {
                exists $S{$_}
                   and exists $pmod->{state}{import}{$_}
                   and not exists $pmod->{state}{preferences}{$_}
             } keys %{$pmod->{state}{import}}),
             (map {
                escape_uri($_) . (defined $P{$_} ? "=" . escape_uri $P{$_} : "");
             } grep {
                exists $S{$_}
                   and not exists $pmod->{state}{import}{$_}
             } keys %P);
   "$url$location+$module" . ($get ? "?$get" : "");
}

=item $url = surl ["module"], arg => value, ...

C<surl> is one of the most often used functions to create urls. The first
argument is a comma-seperated list of target modules that the url should
refer to. If it is missing the url will refer to the current module state,
as will a module name of ".". The most common use is just a singular
module name. Examples:

 .            link to the current module
 menu         link to module "menu" in the current package
 fall/wahl    link to the current module but set the subpackage
              "fall" to module "wahl".
 fall/,menu   link to the menu module and set the subpackage
              "fall" to the default module (with the empty name).

The remaining arguments are parameters that are passed to the new
module. Unlike GET or POST-requests, these parameters are directly passed
into the C<%S>-hash (unless prefixed with a dash), i.e. you can use this
to alter state values when the url is activated. This data is transfered
in a secure way and can be quite large (it will not go over the wire).

When a parameter name is prefixed with a minus-sign, the value will end up
in the (non-persistent) C<%A>-hash instead (for "one-shot" arguments).

Otherwise the argument name is treated similar to a path under unix: If it
has a leading "/", it is assumed to start at the server root, i.e. with
the application location. Relative paths are resolved as you would expect
them. Examples:

(most of the following hasn't been implemented yet)

 /lang         $state{lang}
 /tt/var       $state{'/tt'}{var} -OR- $S{var} in application /tt
 /tt/mod1/var  $state{'/tt'}{'/mod1'}{var}
 ../var        the "var" statekey of the module above in the stack

The following (symbolic) modifiers can also be used:

 SURL_PUSH, <path>
 SURL_UNSHIFT, <path>
   treat the following state key as an arrayref and push or unshift the
   argument onto it.
 
 SURL_POP, <path-or-ref>
 SURL_SHIFT, <path-or-ref>
   treat the following state key as arrayref and pop/shift it.

 SURL_EXEC, <coderef>
   treat the following parameter as code-reference and execute it
   after all other assignments have been done.

 SURL_SAVE_PREFS
   call save_prefs (using SURL_EXEC)
 
 SURL_STYLE_URL
 SURL_STYLE_GET
 SURL_STYLE_STATIC
   set various url styles, see C<surl_style>.
 
 SURL_SUFFIX, $file
   sets the filename in the generated url to the given string. The
   filename is the last component of the url commonly used by browsers as
   the default name to save files. Works only with SURL_STYLE_GET only.

Examples:

 SURL_PUSH, "stack" => 5    push 5 onto @{$S{stack}}
 SURL_SHIFT, "stack"        shift @{$S{stack}}
 SURL_SAVE_PREFS            save the preferences on click
 SURL_EXEC, $cref->refer    execute the PApp::Callback object

=item surl_style [newstyle]

Set a new surl style and return the old one (actually, a token that can be
used with C<surl_style>. C<newstyle> must be one of:

 SURL_STYLE_URL
   The "classic" papp style, the session id gets embedded into the url,
   like C</admin/+modules-/bhWU3DBm2hsusnFktCMbn0>.
 
 SURL_STYLE_GET
   The session id is encoded as the form field named "papp" and appended
   to the url as a get request, e.g. C</admin/+modules-?papp=bhWU3DBm2hsusnFktCMbn0>.
 
 SURL_STYLE_STATIC
   The session id is not encoded into the url, e.g. C</admin/+modules->,
   instead, surl returns two arguments. This must never be set as a
   default using C<surl_style>, but only when using surl directly.

=cut
 
sub surl_style {
   my $old = $surlstyle;
   $surlstyle = $_[1] || $_[0];
   $old;
}
 
=item $ahref = slink contents,[ module,] arg => value, ...

This is just "alink shift, &url", that is, it returns a link with the
given contants, and a url created by C<surl> (see above). For example, to create
a link to the view_game module for a given game, do this:

 <? slink "Click me to view game #$gamenr", "view_game", gamenr => $gamenr :>

The view_game module can access the game number as $S{gamenr}.

=cut

# complex "link content, secure-args"
sub slink {
   alink shift, &surl;
}

=item suburl \@sublink-def [, surl-args]

Creates a URL like C<surl>, but also pushes the current module state
onto the return stack. The sublink-surlargs is an arrayref
containing surl-args used for the "return jump" and is usually just
C<[current_locals]>, i.e. of all local variables.

=item sublink [sublink-surlargs], content [, surl-args]

Just like C<suburl> but creates an C<A HREF> link with given contents.

=item retlink_p

Return true when the return stack has some entries, otherwise false.

=item returl [surl-args]

Return a url that has the effect of returning to the last
C<suburl>-caller.

=item retlink content [, surl-args]

Just like returl, but creates an C<A HREF> link witht he given contents.

=cut

# some kind of subroutine call
sub suburl {
   my $chain = shift;
   if (@$chain & 1) {
      $chain->[0] = \eval_path $chain->[0];
   } else {
      unshift @$chain, \modpath_freeze $modules;
   }
   surl @_, SURL_PUSH, \$state{papp_return}, $chain;
}

# some kind of subroutine call
sub sublink {
   my $chain = shift;
   my $content = shift;
   alink $content, suburl $chain, @_;
}

# is there a backreference?
sub retlink_p() {
   scalar@{$state{papp_return}};
}

sub returl(;@) {
   surl @{$state{papp_return}[-1]}, @_, SURL_POP, \$state{papp_return};
}

sub retlink {
   alink shift, &returl;
}

=item %locals = current_locals

Return the current locals (defined as "local" in a state element) as key => value pairs. Useful for C<sublink>s:

 <? sublink [current_locals], "Log me in!", "login" :>

This will create a link to the login-module. In that module, you should provide a link back
to the current page with:

 <? retlink "Return to the caller" :>

=cut

# Return current local variables as key => value pairs.
sub current_locals {
   map { ($_, $S{$_}) }
       grep exists $ppkg->{local}{$_}
            && exists $ppkg->{local}{$_}{$module},
               keys %S;
}

=item sform [\%attrs,] [module,] arg => value, ...

=item cform [\%attrs,] [module,] arg => value, ...

=item multipart_form [\%attrs,], [module,] arg => value, ...

=item endform

Forms Support

These functions return a <form> or </form>-Tag. C<sform> ("simple form")
takes the same arguments as C<surl> and return a <form>-Tag with a
GET-Method.  C<cform> ("complex form") does the same, but sets method to
POST. Finally, C<multipart_form> is the same as C<cform>, but sets the
encoding-type to "multipart/form-data". The latter data is I<not> parsed
by PApp, you will have to call parse_multipart_form (see below)
when evaluating the form data.

All of these functions except endform accept an initial hashref with
additional attributes (see L<PApp::HTML>), e.g. to set the name attribute
of the generated form elements.

Endform returns a closing </form>-Tag, and I<must> be used to close forms
created via C<sform>/C<cform>/C<multipart_form>.

=cut

sub sform(@) {
   local $surlstyle = _SURL_STYLE_PLAIN;
   PApp::HTML::_tag "form", { ref $_[0] eq "HASH" ? %{+shift} : (), method => 'GET', action => &surl };
}

sub cform(@) {
   PApp::HTML::_tag "form", { ref $_[0] eq "HASH" ? %{+shift} : (), method => 'POST', action => &surl };
}

sub multipart_form(@) {
   PApp::HTML::_tag "form", { ref $_[0] eq "HASH" ? %{+shift} : (), method => 'POST', action => &surl, enctype => "multipart/form-data" };
}

sub endform {
   "</form>";
}

=item parse_multipart_form \&callback;

Parses the form data that was encoded using the "multipart/form-data"
format. For every parameter, the callback will be called with
four arguments: Handle, Name, Content-Type, Content-Type-Args,
Content-Disposition (the latter two arguments are hash-refs, with all keys
lowercased).

If the callback returns true, the remaining parameter-data (if any) is
skipped, and the next parameter is read. If the callback returns false,
the current parameter will be read and put into the C<%P> hash. This is a
no-op callback:

   sub my_callback {
      my ($fh, $name, $ct, $cta, $cd) = @_;
      my $data;
      read($fh, $data, 99999);
      if ($ct =~ /^text\/i) {
         my $charset = lc $cta->{charset};
         # do conversion of $data
      }
      (); # do not return true
   }

The Handle-object given to the callback function is actually an object of
type PApp::FormBuffer (see L<PApp::FormBuffer>). It will
not allow you to read more data than you are supposed to. Also, remember
that the C<READ>-Method will return a trailing CRLF even for data-files.

HINT: All strings (pathnames etc..) are probably in the charset specified
by C<$state{papp_charset}>, but maybe not. In any case, they are octet
strings so watch out!

=cut

# parse a single mime-header (e.g. form-data; directory="pub"; charset=utf-8)
sub parse_mime_header {
   my $line = $_[0];
   $line =~ /([^ ()<>@,;:\\".[\]]+)/g;
   my @r = $1;
   no utf8; # devel7 has no polymorphic regexes
   use bytes; # these are octets!
   warn "$line\n";#d#
   while ($line =~ /
            \G\s*;\s*
            (\w+)=
            (?:
             \"( (?:[^\\\r"]+|\\.)* )\"
             |
             ([^ ()<>@,;:\\".[\]]+)
            )
         /gxs) {
      my $value = $2 || $3;
      # we dequote only the three characters that MUST be quoted, since
      # microsoft is obviously unable to correctly implement even mime headers:
      # filename="c:\xxx". *sigh*
      $value =~ s/\\([\r"\\])/$1/g;
      push @r, lc $1, $value;
   }
   @r;
}

# see PApp::Handler near the end before deciding to call die in
# this function.
sub parse_multipart_form(&) {
   no utf8; # devel7 has no polymorphic regexes
   my $cb  = shift;
   my $ct = $request->header_in("Content-Type");
   $ct =~ m{^multipart/form-data} or return;
   $ct =~ m#boundary=\"?([^\";,]+)\"?#; #FIXME# should use parse_mime_header
   my $boundary = $1;
   my $fh = new PApp::FormBuffer
                fh => $request,
                boundary => $boundary,
                rsize => $request->header_in("Content-Length");

   $request->header_in("Content-Type", "");

   while ($fh->skip_boundary) {
      my ($ct, %ct);
      while ("" ne (my $line = $fh->READLINE)) {
         if ($line =~ /^Content-Type:\s+(.*)$/i) {
            ($ct, %ct) = parse_mime_header $1;
         } elsif ($line =~ /^Content-Disposition:\s+(.*)/i) {
            (undef, %cd) = parse_mime_header $1;
            # ^^^ eq "form-data" or die ";-[";
         }
      }
      my $name = delete $cd{name};
      if (defined $name) {
         $ct ||= "text/plain";
         $ct{charset} ||= $state{papp_charset} || "iso-8859-1";
         unless ($cb->($fh, $name, $ct, \%ct, \%cd)) {
            my $buf;
            while ($fh->read($buf, 16384, length $$buf) > 0)
              { }
         }
      }
   }

   $request->header_in("Content-Length", 0);
}

=item PApp::flush [not exported by default]

Send generated output to the client and flush the output buffer. There is
no need to call this function unless you have a long-running operation
and want to partially output the page. Please note, however, that, as
headers have to be output on the first call, no headers (this includes the
content-type and character set) can be changed after this call.

Flushing does not yet harmonize with output stylesheet processing, for the
semi-obvious reason that PApp::XSLT does not support streaming operation.

=cut

sub _unicode_to_entity {
   sprintf "&#x%x;", $_[0];
}

sub flush_cvt {
   if ($output_charset eq "*") {
      #d##FIXME#
      # do "output charset" negotiation, at the moment this is truely pathetic
      if (utf8_downgrade $$routput, 1) {
         $output_charset = "iso-8859-1";
      } else {
         utf8_upgrade $$routput; # must be utf8 here, but why?
         $output_charset = "utf-8";
      }
   } elsif ($output_charset) {
      # convert to destination charset
      if ($output_charset ne "iso-8859-1" || !utf8_downgrade $$routput, 1) {
         utf8_upgrade $$routput; # wether here or in pconv doesn't make much difference
         if ($output_charset ne "utf-8") {
            my $pconv = PApp::Recode::Pconv::open $output_charset, CHARSET, \&_unicode_to_entity
                           or fancydie "charset conversion to $output_charset not available";
            $$routput = PApp::Recode::Pconv::convert($pconv, $$routput);
         } # else utf-8 == transparent
      } # else iso-8859-1 == transparent
   }

   $state{papp_charset} = $output_charset;
   $request->content_type($output_charset
                          ? "$content_type; charset=$output_charset"
                          : $content_type);
}

sub flush_snd {
   use bytes;

   $request->send_http_header unless $output_p++;
   # $routput should suffice in the next line, but it sometimes doesn't,
   # so just COPY THAT DAMNED THING UNTIL MODPERL WORKS. #d##FIXME#TODO#
   $request->print($$routput) unless $request->header_only;

   $$routput = "";
}

sub flush_snd_length {
   use bytes;
   $request->header_out('Content-Length', length $$routput);
   flush_snd;
}

sub flush {
   flush_cvt;
   local $| = 1;
   flush_snd;
}

=item PApp::send_upcall BLOCK

Immediately stop processing of the current application and call BLOCK,
which is run outside the handler compartment and without state or other
goodies. It has to return one of the status codes (e.g. &PApp::OK). Never
returns.

You should never need to call this function directly, rather use
C<internal_redirect> and other functions that use upcalls to do their
work.

=cut

sub send_upcall(&) {
   local $SIG{__DIE__};
   die bless $_[0], PApp::Upcall;
}

=item redirect url

=item internal_redirect url

Immediately redirect to the given url. I<These functions do not
return!>. C<redirect_url> creates a http-302 (Page Moved) response,
changing the url the browser sees (and displays). C<internal_redirect>
redirects the request internally (in the web-server), which is faster, but
the browser might or might not see the url change.

=cut

sub internal_redirect {
   my $url = $_[0];
   send_upcall {
      # we have to get rid of the old request (think POST, and Apache->content)
      $request->method("GET");
      $request->header_in("Content-Type", "");
      $request->internal_redirect($url);
      return &OK;
   };
}

sub _gen_external_redirect {
   my $url = $_[0];
   $request->status(302);
   $request->header_out(Location => $url);
   undef $output_p;
   $$routput = "
<html>
<head><title>".__"page redirection"."</title></head>
<meta http-equiv=\"refresh\" content=\"0;URL=$url\">
</head>
<body text=\"black\" link=\"#1010C0\" vlink=\"#101080\" alink=\"red\" bgcolor=\"white\">
<large>
This page has moved to <tt>$url</tt>.<br />
<a href=\"$url\">
".__"The automatic redirection  has failed. Please try a <i>slightly</i> newer browser next time, and in the meantime <i>please</i> follow this link ;)"."
</a>
</large>
</body>
</html>
";
   eval { flush(1) };
   return &OK;
}

sub redirect {
   my $url = $_[0];
   send_upcall { _gen_external_redirect $url };
}

=item abort_to surl-args

Similar to C<internal_redirect>, but works the arguments through
C<surl>. This is an easy way to switch to another module/webpage as a kind
of exception mechanism. For example, I often use constructs like these:

 my ($name, ...) = sql_fetch "select ... from game where id = ", $S{gameid};
 abort_to "games_overview" unless defined $name;

This is used in the module showing game details. If it doesn't find the
game it just aborts to the overview page with the list of games.

=cut

sub abort_to {
   internal_redirect &surl;
}

=item abort_with BLOCK

Abort processing of all modules and execute BLOCK as if it were the
top-level module and never return. This function is handy when you are
deeply nested inside a module stack but want to output your own page (e.g.
a file download). Example:

 abort_with {
    content_type "text/plain";
    echo "This is the only line ever output";
 };

=cut

sub abort_with(&) {
   local *output = $routput;
   &{$_[0]};
   send_upcall {
      flush(1);
      return &OK;
   }
}

=item PApp::abort_with_file *FH [, content-type]

Abort processing of the current module stack, set the content-type header
to the content-type given and sends the file given by *FH to the client.
No cleanup-handlers or other thingsw ill get called and the function
does of course not return. This function does I<not> call close on the
filehandle, so if you want to have the file closed after this function
does its job you should not leave references to the file around.

=cut

sub _send_file($$$) {
   my ($fh, $ct, $inclen) = @_;
   $request->content_type($ct) if $ct;
   $request->header_out('Content-Length' => $inclen + (-s _) - tell $fh) if -f $fh;
   $request->send_http_header;
   $request->send_fd($fh);
}

sub abort_with_file($;$) {
   my ($fh, $ct) = @_;
   send_upcall {
      _send_file($fh, $ct, 0);
      return &OK;
   }
}

sub set_cookie {
   $request->header_out(
      'Set-Cookie',
      "PAPP_1984="
      . (PApp::X64::enc $cipher_e->encrypt(pack "VVVV", $userid, 0, 0, rand(1<<30)))
      . "; PATH=/; EXPIRES="
      . unixtime2http($NOW + $cookie_expires, "cookie")
   );
}

sub _debugbox {
   my $r;

   my $pre1 = "<font color='black' size='3'><pre>";
   my $pre0 = "</pre></font>";

   my $_modules = eval { modpath_freeze($modules) } || do { $@ =~ s/ at \(.*$//s; "&lt;$@|".(escape_html PApp::Util::dumpval $modules)."&gt;" };
   my $_curmod  = eval { modpath_freeze($$curmod) } || do { $@ =~ s/ at \(.*$//s; "&lt;$@|".(escape_html PApp::Util::dumpval $$curmod)."&gt;" };

   $r .= "<h2>Status:</h2>$pre1\n",
   $r .= "UsSAS = ($userid,$prevstateid,$stateid,$alternative,$sessionid); location = $location; curpath+module = $curpath+$module;\n";
   $r .= "langs = $langs; modules = $_modules; curmod = $_curmod;\n";

   $r .= "$pre0<h3>Debug Output (dprint &amp; friends):</h3>$pre1\n";
   $r .= escape_html($doutput);

   $r .= "$pre0<h3>Input Parameters (%P):</h3>$pre1\n";
   $r .= escape_html(PApp::Util::dumpval(\%P));

   $r .= "$pre0<h3>Input Arguments (%arguments):</h3>$pre1\n";
   $r .= escape_html(PApp::Util::dumpval(\%arguments));

   $r .= "${pre0}<h3>Global State (%state):</h3>$pre1\n";
   $r .= escape_html(PApp::Util::dumpval(\%state));

   if (0) { # nicht im moment, nutzen sehr gering
   $r .= "$pre0<h3>Application Definition (%\$papp):</h3>$pre1\n";
   $r .= escape_html(PApp::Util::dumpval($papp,{
            #CB     => $papp->{cb}||{},
            #CB_SRC => $papp->{cb_src}||{},
         }));
   }

   $r .= "$pre0<h3>Apache->request:</h3>$pre1\n";
   $r .= escape_html($request->as_string);

   $r .= "$pre0\n";

   $r =~ s/&#0;/\\0/g; # escape binary zero
   $r;
}

=item debugbox

Create a small table with a single link "[switch debug mode
ON]". Following that link will enable debugigng mode, reload the current
page and display much more information (%state, %P, %$papp and the request
parameters). Useful for development. Combined with the admin package
(L<macro/admin>), you can do nice things like this in your page:

 #if admin_p
   <: debugbox :>
 #endif

=cut

sub debugbox {
   echo "<br /><table cellpadding='10' bgcolor='#e0e0e0' width='100%' align='center'><tr><td id='debugbox'><font size='6' face='Helvetica' color='black'>";
   if (0||$state{papp_debug}) {
      echo slink("[switch debug mode OFF]", "/papp_debug" => undef);
      echo _debugbox;
   } else {
      echo slink("[switch debug mode ON]", "/papp_debug" => 1);
   }
   echo "</font></td></tr></table>";
}

=item language_selector $translator, $current_langid

Create (and output) html code that allows the user to select one of the
languages reachable through the $translator. This function might move
elsewhere, as it is clearly out-of-place here ;)

=cut

sub language_selector {
   my $translator = shift;
   my $current = shift;
   for my $lang ($translator->langs) {
      my $name = PApp::I18n::translate_langid($lang, $lang);
      if ($lang ne $current) {
         echo slink "[$name]", SURL_SET_LANG, $lang;
      } else {
         echo "[$name]";
      }
   }
   
}

#############################################################################
# path stuff, ought to go into xs, at least
#############################################################################

sub abs_path($) {
   expand_path(shift, $curpath);
}

# ($path, $key) = split_path $keypath;
sub split_path($) {
   $_[0] =~ /^(.*)\/([^\/]*)$/;
}

#############################################################################

# should be all my variables, broken due to mod_perl

   $st_fetchstate;
   $st_newstateid;
   $st_updatestate;

   $st_reload_p;

   $st_fetchprefs;
   $st_newuserid;
   $st_updateprefs;

   $st_updateatime;

=item reload_p

Return the count of reloads, i.e. the number of times this page
was reloaded (which means the session was forked).

This is a relatively costly operation (a database access), so do not do it
by default, but only when you need it.

=cut

sub reload_p {
   if ($prevstateid) {
      $st_reload_p->execute($prevstateid, $alternative);
      $st_reload_p->fetchrow_arrayref->[0]-1
   } else {
      0;
   }
}

# forcefully (re-)read the user-prefs and returns the "new-user" flag
# reads all user-preferences (no args) or only the preferences
# for the given path (arguments is given)
sub load_prefs(@) {
   $st_fetchprefs->execute($userid);

   if (defined (my $prefs = $st_fetchprefs->fetchrow_array)) {
      $prefs &&= Storable::thaw decompress $prefs;

      my @keys;
      for my $path (@_ ? @_ : keys %preferences) {
         if ($path && !exists $state{$path}) {
            return if @_ == 1;
         } else {
            my $h = $path ? $state{$path} : \%state;
            while (my ($k, $v) = each %{$prefs->{$path}}) {
               $h->{$k} = $v;
            }
         }
      }

      1;
   } else {
      undef $userid;
   }
}

=item save_prefs

Save the preferences for all currently loaded applications.

=cut

sub save_prefs {
   my $prefs;

   $st_fetchprefs->execute($userid);

   if ($prefs = $st_fetchprefs->fetchrow_array) {
      $prefs = Storable::thaw decompress $prefs;
   } else {
      $prefs = {};
   }

   while (my ($path, $keys) = each %preferences) {
      next if $path && !exists $state{$path};
      
      my $h = $path ? $state{$path} : \%state;
      $prefs->{$path} = { map { $_ => $h->{$_} } grep { exists $h->{$_} } @$keys };
   }

   $st_updateprefs->execute(compress Storable::nfreeze($prefs), $userid);
}

=item switch_userid $newuserid

Switch the current session to a new userid. This is useful, for example,
when you do your own user accounting and want a user to log-in. The new
userid must exist, or bad things will happen, with the exception of userid
zero, which creates a new userid (and sets C<$userid>).

=cut

sub switch_userid {
   my $oldid = $userid;
   $userid = shift;
   unless ($userid) {
      $st_newuserid->execute;
      $userid = sql_insertid($st_newuserid);
      $papp->event("newuser");
   } else {
      load_prefs "", keys %preferences;
   }
   if ($userid != $oldid) {
      $state{papp_switch_newuserid} = $userid;
      $state{papp_last_cookie} = 0; # unconditionally re-set the cookie
   }
}

sub update_state {
   %arguments = %A = ();
   $st_updatestate->execute(compress Storable::mstore(\%state),
                            $userid, $sessionid, $stateid) if $stateid;
   &_destroy_state; # %P = %S = %state = (), but in a safe way
   undef $stateid;
}

sub flush_pkg_cache  {
   DBH->do("delete from pkg");
}

################################################################################################

$SIG{__WARN__} = sub {
   my $msg = $_[0];
   $msg =~ s/^/Warning: /gm;
   PApp->warn($msg);
};

sub PApp::Base::warn {
   if ($request) {
      $request->warn($_[1]);
   } else {
      print STDERR $_[1];
   }
};

=item PApp::config_eval BLOCK

Evaluate the block and call PApp->config_error if an error occurs. This
function should be used to wrap any perl sections that should NOT keep
the server from starting when an error is found during configuration
(e.g. Apache <Perl>-Sections or the configuration block in CGI
scripts). PApp->config_error is overwritten by the interface module and
should usually do the right thing.

=cut

our $eval_level = 0;

sub config_eval(&) {
   if (!$eval_level) {
      local $eval_level = 1;
      local $SIG{__DIE__} = \&PApp::Exception::diehandler;
      my $retval = eval { &{$_[0]} };
      config_error PApp $@ if $@;
      return $retval;
   } else {
      return &{$_[0]};
   }
}

my %app_cache;
# find app by mountid
sub load_app($$) {
   my $class = shift;
   my $appid = shift;

   return $app_cache{$appid} if exists $app_cache{$appid};

   my $st = sql_exec DBH,
                     \my($name, $path, $mountconfig, $config),
                     "select name, path, mountconfig, config from app
                      where id = ?", $appid;
   $st->fetch or fancydie "load_app: no such application", "appid => $appid";

   my %config = eval $config;

   $@ and fancydie "error while evaluating config for [appid=$appid]", $@,
      info => [path => $path],
      info => [name => $name],
      info => [appid => $appid],
      info => [config => PApp::Util::format_source $_config];

   $app_cache{$_[0]} = new PApp::Application
      delayed	=> 1,
      mountconfig	=> $mountconfig,
      url_prefix_nossl => $url_prefix_nossl,
      url_prefix_ssl => $url_prefix_ssl,
      url_prefix_sslauth => $url_prefix_sslauth,
      %config,
      appid		=> $appid,
      path		=> $path,
      name		=> $name;
}

sub PApp::Base::mount_appset {
   my $self = shift;
   my $appset = shift;
   my @apps;

   config_eval {
      my $setid = sql_fetch DBH, "select id from appset where name like ?", $appset;
      $setid or fancydie "$appset: unable to mount nonexistant appset";
   };

   my $st = sql_exec
               DBH,
               \my($id),
               "select app.id from app, appset where app.appset = appset.id and appset.name = ?",
               $appset;

   while ($st->fetch) {
      config_eval {
         my $papp = PApp->load_app($id);
         PApp->mount($papp);
         push @apps, $papp;
      }
   }
   @apps;
}

sub PApp::Base::mount_app {
   my $self = shift;
   my $app = shift;
   my $id;

   config_eval {
      $id = sql_fetch DBH, "select id from app where name like ?", $app;
      $id or fancydie "$app: unable to mount nonexistant application $id";

      $app = PApp->load_app($id);
      PApp->mount($app);
   };

   $app;
}

sub PApp::Base::mount {
   my $self = shift;
   my $papp = shift;

   my %arg = @_;

   $papp{$papp->{appid}} = $papp;

   $papp->mount;

   $papp->load unless $arg{delayed} || $PApp::delayed;
}

sub list_apps() {
   keys %papp;
}

sub handle_error($) {
   my $exc = $_[0];

   UNIVERSAL::isa($exc, PApp::Exception)
      or $exc = new PApp::Exception error => 'Script evaluation error',
                                    info => [$exc];
   $exc->errorpage;
   eval { update_state };
   eval { flush_cvt };
   if ($request) {
      $request->log_reason($exc, $request->filename);
   } else {
      print STDERR $exc;
   }
}

################################################################################################
#
#   the PApp request handler
#
# on input, $location, $pathinfo, $request and $papp must be preset
#
sub _handler {
   my $state;
   my $filename;

   $NOW = time;

   undef $stateid;

   defined $logfile and open (local *STDERR, ">>", $logfile);

   $output_p = 0;
   $doutput = "";
   $output = "";
   tie *STDOUT, PApp::Catch_STDOUT;
   $content_type = "text/html";
   $output_charset = "*";

   eval {
      local $SIG{__DIE__} = \&PApp::Exception::diehandler;

      $DBH = DBH;

      %P = %arguments = ();
      _set_params PApp::HTML::parse_params $request->query_string;
      _set_params PApp::HTML::parse_params $request->content
         if $request->header_in("Content-Type") eq "application/x-www-form-urlencoded";

      my $state =
            delete $P{papp}
            || ($pathinfo =~ s%/([\-.a-zA-Z0-9]{22,22})$%% && $1);

      if ($state) {
         ($userid, $prevstateid, $alternative, $sessionid) = unpack "VVVxxxx", $cipher_d->decrypt(PApp::X64::dec $state);
         $st_fetchstate->execute($prevstateid);

         $state = $st_fetchstate->fetchrow_arrayref;
      }

      if ($state) {
         $st_newstateid->execute($prevstateid, $alternative);
         $stateid = sql_insertid $st_newstateid;

         *state = Storable::mretrieve decompress $state->[0];

         $nextid = $state->[2];
         $sessionid = $state->[3];

         if ($state->[1] != $userid) {
            if ($state->[1] != $state{papp_switch_newuserid}) {
               fancydie "User id mismatch", "maybe someone is tampering?";
            } else {
               $userid = $state{papp_switch_newuserid};
            }
         }
         delete $state{papp_switch_newuserid};

         set_alternative $state{papp_alternative}[$alternative];

         $papp = $papp{$state{papp_appid}}
                 or fancydie "Application not mounted", $location,
                             info => [appid => $state{papp_appid}];

      } else {
         $st_newstateid->execute(0, 0);
         $sessionid = $stateid = sql_insertid $st_newstateid;

         $state{papp_appid} = $papp->{appid};

         $modules = $pathinfo ? modpath_thaw substr $pathinfo, 1 : ();

         $alternative = 0;
         $prevstateid = 0;

         if ($request->header_in('Cookie') =~ /PAPP_1984=([0-9a-zA-Z.-]{22,22})/) {
            ($userid, undef, undef, undef) = unpack "VVVxxxx", $cipher_d->decrypt(PApp::X64::dec $1);
         } else {
            undef $userid;
         }

         if ($userid) {
            if (load_prefs "") {
               $state{papp_visits}++;
               push @{$state{papp_execonce}}, $save_prefs_cb;
            }
         }
      }
      $state{papp_alternative} = [];

      $langs = lc $state{papp_charset};
      if ($langs eq "utf-8") {
         # force utf8 on
         for (keys %P) {
            utf8_on $_ for ref $P{$_} ? @{$P{$_}} : $P{$_};
         }
      } elsif ($langs ne "" and $langs ne "iso-8859-1") {
         my $pconv = PApp::Recode::Pconv::open CHARSET, $langs
                        or fancydie "charset conversion from $langs not available";
         for (keys %P) {
            $_ = utf8_on $pconv->convert_fresh($_) for ref $P{$_} ? @{$P{$_}} : $P{$_};
         }
      }

      $langs = "$state{lang},".$request->header_in("Content-Language").",de,en";

      $papp->check_deps if $checkdeps;

      unless ($papp->{compiled}) {
         $papp->load_code;
         $papp->event("init");
         $papp->event("childinit");
      }

      # do not use for, as papp_execonce might actually grow during
      # execution of these callbacks
      &{shift @{$state{papp_execonce}}} while @{$state{papp_execonce}};
      delete $state{papp_execonce};

      if ($userid) {
         if ($state{papp_last_cookie} < $NOW - $cookie_reset) {
            set_cookie;
            $state{papp_last_cookie} = $NOW;
            push @{$state{papp_execonce}}, $save_prefs_cb;
         }
      } else {
         switch_userid 0;
      }

      PApp::Application::run($papp);

      flush_cvt;

      update_state;
      undef $stateid;

      1;
   } or do {
      if (UNIVERSAL::isa $@, PApp::Upcall) {
         my $upcall = $@;
         eval { update_state };
         untie *STDOUT; open STDOUT, ">&1";
         return &$upcall;
      } else {
         handle_error($@);
      }
   };

   untie *STDOUT; open STDOUT, ">&1";

   flush_snd_length;

   # now eat what the browser sent us (might give locking problems, but
   # that's not our bug).
   parse_multipart_form {} if $request->header_in("Content-Type") =~ m{^multipart/form-data};

   undef $request; # preserve memory

   return &OK;
}

sub PApp::Catch_STDOUT::TIEHANDLE {
   bless \(my $unused), shift;
}

sub PApp::Catch_STDOUT::PRINT {
   shift;
   $output .= join "", @_;
   1;
}

sub PApp::Catch_STDOUT::PRINTF {
   shift;
   $output .= sprintf(shift,@_);
   1;
}

sub PApp::Catch_STDOUT::WRITE {
   my ($self, $data, $length) = @_;
   $output .= $data;
   $length;
}

1;

=back

=head1 SEE ALSO

The C<macro/admin>-package on the distribution, the demo-applications
(.papp-files).

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

