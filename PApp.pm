=head1 NAME

PApp - multi-page-state-preserving web applications

=head1 SYNOPSIS

 * this module is at a very early stage of development and *
 * requires quite an elaborate setup (see the INSTALL file) *
 * documentation will certainly be improved *

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
Apache::Registry page is much slower than the equivalent PApp application
(or much, much more complicated);

=item * Embedded Perl. You can freely embed perl into your documents. In
fact, You can do things like these:

   <h1>Names and amounts</h1>
   <:
      my $st = sql_exec "select name, amount from ...",
               [\my($name, $amount];

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

=item * Perl5.6 is required. While not originally an disadvantage in my
eyes, Randal Schwartz asked me to provide some explanation on why this is
so:

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

#   imports
use Carp;
use FileHandle ();
use File::Basename qw(dirname);

use Storable;

use Compress::LZV1;
use Crypt::Twofish2;

use PApp::Config;
use PApp::FormBuffer;
use PApp::Exception;
use PApp::I18n;
use PApp::HTML;

BEGIN {
   $VERSION = 0.07;

   @ISA = qw/Exporter/;

   @EXPORT = qw(

         debugbox

         surl slink sform cform suburl sublink retlink_p returl retlink
         current_locals reference_url multipart_form parse_multipart_form
         endform redirect internal_redirect abort_to

         $request $location $module $pmod $NOW
         *state %P %A *S *L save_prefs $userid
         reload_p switch_userid

         dprintf dprint echo capture $request 
         insert_module
         
         __ N_

   );

   require XSLoader;
   XSLoader::load PApp, $VERSION;
}

#   globals
#   due to what I call bugs in mod_perl, my variables do not survive
#   configuration time

   $translator;

   $configured;

   $key;
   $cipher_e;
   $cipher_d;
   $statedb;
   $statedb_user;
   $statedb_pass;

   $stateid;     # uncrypted state-id
   $prevstateid;

our $userid;      # uncrypted user-id
our $alternative; # number of alternatives already generated

our %state;
our %S;
our %P;
our %A;

our %papp;        # all loaded applications, indexed by location

our $NOW;         # the current time (so you only need to call "time" once)

# other globals. must be globals since they should be accessible outside
our $output;      # the collected output (must be global)
our $doutput;     # debugging output
our $location;    # the current location (a.k.a. application)
our $module;      # the current module(-string)
our $pmod;        # the current location (a.k.a. module)
our $request;     # the apache request object

our $statedbh;    # papp database handle

our $langs;       # contains the current requested languages (e.g. "de, en-GB")

   $libdir;   # library directory
   $i18ndir;  # i18n directory

   $cookie_reset   = 86400;       # reset the cookie at most every ... seconds
   $cookie_expires = 86400 * 365; # cookie expiry time (one year, whooo..)

   $checkdeps;   # check dependencies (relatively slow)

# we might be slow, but we are rarely called ;)
sub __($) {
   # not yet: FIXME #d#
   #$translator->get_language($langs)->fetch($_[0]);
   $_[0];
}

sub N_($) { $_[0] }

=head1 GLOBAL VARIABLES

Some global variables are free to use and even free to change (yes,
we still are about speed, not abstraction). In addition to these
variables, the globs C<*state> and C<*S> (and in future versions C<*L>)
are reserved. This means that you cannot define a scalar, sub, hash,
filehandle or whatsoever with these names.

=over 4

=item $request [read-only]

The Apache request object (L<Apache>), the  same as returned by C<Apache->request>.

=item %state [read-write, persistent]

A system-global hash that can be used for almost any purpose, such as
saving (global) preferences values. All keys with prefix C<papp> are
reserved for use by this module. Everything else is yours.

=item %S [read-write, persistent]

Similar to C<%state>, but is local to the current application. Input
arguments prefixed with a dash end up here.

=item %L [read-write, persistent]

(NYI)

=item %A [read-write, input only]

A global hash that contains the arguments to the current module. Arguments
to the module can be given to surl or any other function that calls it, by
prefixing parameter names with a minus sign (i.e. "-switch").

=item %P [read-write, input only]

Similar to C<%A>, but it instead contains the parameters from
forms submitted via GET or POST (C<see parse_multipart_form>,
however). Everything in this hash is insecure by nature and must should be
used carefully.

=item $userid [read-only]

The current userid. User-Id's are automatically assigned to every incoming
connection, you are encouraged to use them for your own user-databases,
but you mustn't trust them.

=item $pmod (a hash-ref) [read-only]

The current module (don't ask). The only user-accessible keys are:

 lang     a hash-ref enumerating the available languages, values are
          either language I<Names> or references to another language-id.
 config   the argument to the C<config>option given to  C<mount>.

=item $location [read-only]

The location value from C<mount>.

=item $module [read-only]

The current module I<within> the application.
 
=back

=head1 FUNCTIONS/METHODS

=over 4

=item PApp->search_path(path...);

Add a directory in where to search for included/imported/"module'd" files.

=item PApp->configure(name => value...);

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
 checkdeps     when set, papp will check the .papp file dates for
               every request (slow!!) and will reload the app when necessary.

=item PApp->mount(location => 'uri', src => 'file.app', ... );

 location[*]   The URI the application is moutned under, must start with "/"
 src[*]        The .papp-file to mount there
 config        Will be available to the module as $pmod->{config}

 [*] required attributes

=cut

sub event {
   my $event = shift;
   for $pmod (values %papp) {
      $pmod->{cb}{$event}() if exists $pmod->{cb}{$event};
   }
}

sub search_path {
   shift;
   goto &PApp::Config::search_path;
}

sub configure {
   my $self = shift;
   my %a = @_;
   my $caller = caller;

   $statedb      ||= $PApp::Config{STATEDB};
   $statedb_user ||= $PApp::Config{STATEDB_USER};
   $statedb_pass ||= $PApp::Config{STATEDB_PASS};
   $libdir       ||= $PApp::Config{LIBDIR};
   $i18ndir      ||= $PApp::Config{I18NDIR};
   $key          ||= $PApp::Config{CIPHERKEY};

   exists $a{libdir} and $libdir = $a{libdir};
   exists $a{pappdb} and $statedb = $a{pappdb};
   exists $a{pappdb_user} and $statedb_user = $a{pappdb_user};
   exists $a{pappdb_pass} and $statedb_pass = $a{pappdb_pass};
   exists $a{cookie_reset} and $cookie_reset = $a{cookie_reset};
   exists $a{cookie_expires} and $cookie_expires = $a{cookie_expires};
   exists $a{checkdeps} and $checkdeps = $a{checkdeps};
   exists $a{cipherkey} and $key = $a{cipherkey};
}

sub configured {
   # mod_perl does this to us....
   #$configured and warn "WARNING: PApp::configured called multiple times\n";

   if (!$configured) {
      if (!$key) {
         warn "WARNING: no cipherkey was specified, this is an insecure configuration";
         $key = "c9381ddf6cfe96f1dacea7e7a86887542d6aaa6476cf5bbf895df0d4f298e741";
      }
      my $key = pack "H*", $key;
      $cipher_d = new Crypt::Twofish2 $key;
      $cipher_e = new Crypt::Twofish2 $key;

      # fake module for papp itself

      $papp{""} = {
         i18ndir => $i18ndir,
         name    => 'papp',
         lang    => { 'de' => "Deutsch", 'en' => "English" },
         file    => {
            "$libdir/macro/admin.papp"    => { lang => 'en' },
            "$libdir/macro/util.papp"     => { lang => 'en' },
            "$libdir/macro/editform.papp" => { lang => 'en' },
            $INC{"PApp.pm"}               => { lang => 'en' },
            $INC{"PApp/FormBuffer.pm"}    => { lang => 'en' },
            $INC{"PApp/I18n.pm"}          => { lang => 'en' },
            $INC{"PApp/Exception.pm"}     => { lang => 'en' },
            $INC{"PApp/Parser.pm"}        => { lang => 'en' },
         },
      };

      $translator = PApp::I18n::open_translator("$i18ndir/papp", keys %{$papp{""}{lang}});

      $configured = 1;

      event 'init';
   }
}

sub configured_p {
   $configured;
}

sub expand_path {
   my $module = shift;
   for (PApp::Config::search_path) {
      return "$_/$module"      if -f "$_/$module";
      return "$_/$module.papp" if -f "$_/$module.papp";
   }
   undef;
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
   local $output;
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
                   and not exists $pmod->{state}{sysprefs}{$_}
             } keys %{$pmod->{state}{import}}),
             (map {
                escape_uri($_) . (defined $P{$_} ? "=" . escape_uri $P{$_} : "");
             } grep {
                exists $S{$_}
                   and not exists $pmod->{state}{import}{$_}
             } keys %P);
   "$url$location/$module" . ($get ? "?$get" : "");
}

=item $url = surl ["module"], arg => value, ...

C<surl> is one of the most often used functions to create urls. The first
argument is the name of a module that the url should refer to. If it is
missing the url will refer to the current module.

The remaining arguments are parameters that are passed to the new
module. Unlike GET or POST-requests, these parameters are directly passed
into the C<%S>-hash (unless prefixed with a dash), i.e. you can use this
to alter state values when the url is activated. This data is transfered
in a secure way and can be quite large (it will not go over the wire).

When a parameter name is prefixed with a minus-sign, the value will end up
in the (non-persistent) C<%A>-hash instead (for "one-shot" arguments).

=cut

sub surl(@) {
   my $module = @_ & 1 ? shift : $module;
   my $location = $module =~ s/^(\/.*?)(?:\/([^\/]*))?$/$2/ ? $1 : $location;

   $alternative++;
   $state{papp}{alternative}[$alternative] = ["/papp_module" => $module, @_];

   "$location/"
      . (PApp::X64::enc $cipher_e->encrypt(pack "VVVV", $userid, $stateid, $alternative, rand(1<<30)))
      . "/$module";
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

=item $ahref = sublink [sublink-def], content,[ module,] arg => value, ...

=item retlink_p

=item returl

=item retlink

*FIXME* (see also C<current_locals>)

=cut

# some kind of subroutine call
sub suburl {
   my $chain = shift;
   unshift @$chain, "$location/$module" unless @$chain & 1;
   surl @_, \$state{papp}{return} => [@{$state{papp}{return}}, $chain];
}

# some kind of subroutine call
sub sublink {
   my $chain = shift;
   my $content = shift;
   alink $content, suburl $chain, @_;
}

# is there a backreference?
sub retlink_p() {
   scalar@{$state{papp}{return}};
}

sub returl(;@) {
   my @papp_return = @{$state{papp}{return}};
   surl @{pop @papp_return}, @_, \$state{papp}{return} => \@papp_return;
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
       grep exists $pmod->{state}{local}{$_}
            && exists $pmod->{state}{local}{$_}{$module},
               keys %S;
}

=item sform [module, ]arg => value, ...

=item cform [module, ]arg => value, ...

=item multipart_form [module, ]arg => value, ...

=item endform

Forms Support

These functions return a <form> or </form>-Tag. C<sform> ("simple form")
takes the same arguments as C<surl> and return a <form>-Tag with a
GET-Method.  C<cform> ("complex form") does the same, but sets method to
POST. Finally, C<multipart_form> is the same as C<cform>, but sets the
encoding-type to "multipart/form-data". The latter data is I<not> parsed
by PApp, you will have to call parse_multipart_form (see below)
when evaluating the form data.

Endform returns a closing </form>-Tag, and I<must> be used to close forms
created via C<sform>/C<cform>/C<multipart_form>. It can take additional
key => value argument-pairs (just like the *form-functions) and must be called in a
paired way.

=cut

my @formstack;

sub sform(@) {
   push @formstack, $alternative + 1;
   '<form method=GET action="'.&surl.'">';
}

sub cform(@) {
   push @formstack, $alternative + 1;
   '<form method=POST action="'.&surl.'">';
}

sub multipart_form(@) {
   push @formstack, $alternative + 1;
   '<form method=POST enctype="multipart/form-data" action="'.&surl.'">';
}

sub endform {
   my $alternative = pop @formstack;
   push @{$state{papp}{alternative}[$alternative]}, @_;
   "</form>";
}

=item parse_multipart_form \&callback;

Parses the form data that was encoded using the "multipart/form-data"
format. For every parameter, the callback will be called with four
arguments: Handle, Name, Content-Type, Content-Disposition (the latter is
a hash-ref, with all keys lowercased).

If the callback returns true, the remaining parameter-data (if any) is
skipped, and the next parameter is read. If the callback returns false,
the current parameter will be read and put into the C<%P> hash.

The Handle-object given to the callback function is actually an object of
type PApp::FormBuffer (see L<PApp::FormBuffer>). It will
not allow you to read more data than you are supposed to. Also, remember
that the C<READ>-Method will return a trailing CRLF even for data-files.

=cut

sub parse_multipart_form(&) {
   my $cb  = shift;
   my $ct = $request->header_in("Content-Type");
   $ct =~ m{^multipart/form-data} or return;
   $ct =~ m#boundary=\"?([^\";,]+)\"?#;
   my $boundary = $1;
   my $fh = new PApp::FormBuffer
                fh => $request,
                boundary => $boundary,
                rsize => $request->header_in("Content-Length");

   $request->header_in("Content-Type", "");

   while ($fh->skip_boundary) {
      my ($ct, %cd);
      while ("" ne (my $line = $fh->READLINE)) {
         if ($line =~ /^Content-Type: (.*)$/i) {
            $ct = $1;
         } elsif ($line =~ s/^Content-Disposition: form-data//i) {
            while ($line =~ /\G\s*;\s*(\w+)=\"((?:[^"]+|\\")*)\"/gc) {
               $cd{lc $1} = $2;
            }
         }
      }
      my $name = delete $cd{name};
      if (defined $name) {
         unless ($cb->($fh, $name, $ct, \%cd)) {
            my $buf = \$P{$name};
            $$buf = "";
            while ($fh->read($$buf, 4096, length $$buf) > 0)
              {
              }
            $$buf =~ s/\15\12$//;
         }
      }
   }

   $request->header_in("Content-Length", 0);
}

=item redirect url

=item internal_redirect url

Immediately redirect to the given url. I<These functions do not
return!>. C<redirect_url> creates a http-302 (Page Moved) response,
changing the url the browser sees (and displays). C<internal_redirect>
redirects the request internally (in the web-server), which is faster, but
the browser will not see the url change.

=cut

sub internal_redirect {
   die { internal_redirect => $_[0] };
}

sub redirect {
   $request->status(302);
   $request->header_out(Location => $_[0]);
   $output = "
<html>
<head><title>".__"page redirection"."</title></head>
</head>
<body text=black link=\"#1010C0\" vlink=\"#101080\" alink=red bgcolor=white>
<large>
<a href=\"$_[0]\">
".__"The automatic redirection  has failed. Please try a <i>slightly</i> newer browser next time, and in the meantime <i>please</i> follow this link ;)"."
</a>
</large>
</body>
</html>
";
   die { };
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

sub set_cookie {
   $request->header_out(
      'Set-Cookie',
      "PAPP_1984="
      . (PApp::X64::enc $cipher_e->encrypt(pack "VVVV", $userid, 0, 0, rand(1<<30)))
      . "; PATH=/; EXPIRES="
      . unixtime2http($NOW + $cookie_expires, "cookie")
   );
}

sub dumpval {
   require Data::Dumper;
   my $d = new Data::Dumper([$_[0]], ["*var"]);
   $d->Terse(1);
   $d->Quotekeys(0);
   #$d->Bless(...);
   $d->Seen($_[1]) if @_ > 1;
   $d->Dump();
}

sub _debugbox {
   my $r;

   my $pre1 = "<font size=7 face=Courier color=black><pre>";
   my $pre0 = "</pre></font>";

   $r .= <<EOF;
UsSA = ($userid,$prevstateid,$stateid,$alternative); location = $location; module = $module; langs = $langs<br>
EOF

   $r .= "<h3>Debug Output (dprint &amp; friends):</h3>$pre1\n";
   $r .= escape_html($doutput);

   $r .= "$pre0<h3>Input Parameters (%P):</h3>$pre1\n";
   $r .= escape_html(dumpval(\%P));

   $r .= "$pre0<h3>Input Arguments (%A):</h3>$pre1\n";
   $r .= escape_html(dumpval(\%A));

   $r .= "${pre0}<h3>Global State (%state):</h3>$pre1\n";
   $r .= escape_html(dumpval(\%state));

   $r .= "$pre0<h3>Module Definition (%\$pmod):</h3>$pre1\n";
   $r .= escape_html(dumpval($pmod,{
            CB     => $pmod->{cb},
            CB_SRC => $pmod->{cb_src},
            MODULE => $pmod->{module},
            IMPORT => $pmod->{import},
         }));

   $r .= "$pre0<h3>Apache->request:</h3>$pre1\n";
   $r .= escape_html($request->as_string);

   $r .= "$pre0\n";

   $r;
}

=item debugbox

Create a small table with a single link "[switch debug mode
ON]". Following that link will enable debugigng mode, reload the current
page and display much more information (%state, %P, %$pmod and the request
parameters). Useful for development. Combined with the admin package
(L<macro/admin>), you can do nice things like this in your page:

 #if admin_p
   <: debugbox :>
 #endif

=cut

sub debugbox {
   echo "<br><table bgcolor=\"#e0e0e0\" width=\"100%\" align=center><tr><td><font size=7 face=Helvetica color=black><td id=debugbox>";
   if ($state{papp_debug}) {
      echo "<hr>" . slink("<h1>[switch debug mode OFF]</h1>", "/papp_debug" => 0) . "\n";
      echo _debugbox;
   } else {
      echo "<hr>" . slink("<h1>[switch debug mode ON]</h1>", "/papp_debug" => 1) . "\n";
   }
   echo "</font></td></table>";
}

#
#   send HTML error page
#   shamelessly stolen from ePerl
#
sub errorpage {
    my $err = shift;

    $request->content_type('text/html; charset=ISO-8859-1');
    $request->send_http_header;
    $request->print($err->as_html(body =>  _debugbox));
    $request->log_reason("PApp: $err", $request->filename);
}

#############################################################################

sub unescape {
   local $_ = shift;
   y/+/ /;
   s/%([0-9a-fA-F][0-9a-fA-F])/pack "c", hex $1/ge;
   $_;
}

# parse application/x-www-form-urlencoded
sub parse_params {
   for (split /[&;]/, $_[0]) {
      /([^=]+)=(.*)/ and $P{$1} = unescape $2;
   }
}

=item insert_module "module"

Switch permanently module "module". It's output is inserted at the point
of the call to switch_module.

=cut

sub insert_module($) {
   $module = shift;
   $pmod->{module}{$module}{cb}->();
}

# should be all my variables, broken due to mod_perl

   $stdout;
   $stderr;

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
      $st_reload_p->execute($prevstateid);
      $st_reload_p->fetchrow_arrayref->[0]-1
   } else {
      0;
   }
}

# forcefully read the user-prefs, return new-user-flag
sub get_userprefs {
   my ($prefs, $k, $v);
   $st_fetchprefs->execute($userid);
   if (my ($prefs) = $st_fetchprefs->fetchrow_array) {
      $prefs = $prefs ? Storable::thaw decompress $prefs : {};

      $state{$k} = $v while ($k,$v) = each %{$prefs->{sys}};
      $S{$k}     = $v while ($k,$v) = each %{$prefs->{loc}{$location}};

      1;
   } else {
      undef $userid;
   }
}

=item switch_userid $newuserid

Switch the current session to a new userid. This is useful, for example,
when you do your own user accounting and want a user to log-in. The new
userid must exist, or bad things will happen.

=cut

sub switch_userid {
   my $oldid = $userid;
   $userid = shift;
   unless ($userid) {
      $st_newuserid->execute;
      $userid = $st_newuserid->{mysql_insertid};
      $pmod->{cb}{newuser}->();
      $newuser = 1;
   } else {
      get_userprefs;
   }
   if ($userid != $oldid) {
      $state{papp}{switch_newuserid} = $userid;
      $state{papp_last_cookie} = 0; # unconditionally re-set the cookie
   }
}

sub save_prefs {
   my %prefs;

   while (my ($key,$v) = each %state) {
      $prefs{sys}{$key}            = $v if $pmod->{state}{sysprefs}{$key};
   }
   while (my ($key,$v) = each %S) {
      $prefs{loc}{$location}{$key} = $v if $pmod->{state}{preferences}{$key};
   }

   $st_updateprefs->execute(compress Storable::freeze(\%prefs), $userid);
}

sub update_state {
   $st_updatestate->execute(compress Storable::freeze(\%state), $userid, $stateid);
}

sub reload_app {
   my ($path, $config) = @_;
   my $pmod = load_file PApp::Parser $path;
   $pmod->{config} = $config;
   $pmod->compile;
   $pmod;
}

# *apache_request = \&Apache::request;

#
#   the mod_perl handler
#
sub handler {
   $request = shift;

   my $state;
   my $filename;

   $NOW = time;

   # create a request object (not sure if needed)
   apache_request('Apache', $request);

   $sent_http_headers = 0;

   $stdout = tie *STDOUT, PApp::FHCatcher;
   $stderr = tie *STDERR, PApp::FHCatcher;

   *output = $stdout;
   $doutput = "";

   $request->content_type('text/html; charset=ISO-8859-1');

   eval {
      $newuser = 0;

      $statedbh = PApp::SQL::connect_cached("PAPP_1", $statedb, $statedb_user, $statedb_pass, {
         RaiseError => 1,
      }, sub {
         my $dbh = shift;
         $st_fetchstate  = $dbh->prepare("select state, userid, previd from state where id = ?");
         $st_newstateid  = $dbh->prepare("insert into state (previd) values (?)");
         $st_updatestate = $dbh->prepare("update state set state = ?, userid = ? where id = ?");

         $st_reload_p    = $dbh->prepare("select count(*) from state where previd = ?");

         $st_fetchprefs  = $dbh->prepare("select prefs from user where id = ?");
         $st_newuserid   = $dbh->prepare("insert into user () values ()");
         $st_updateprefs = $dbh->prepare("update user set prefs = ? where id = ?");
      }) or fancydie "error connecting to papp database", $DBI::errstr;

      # import filename from Apache API
      $location = $request->uri;

      my $pathinfo = $request->path_info;
      $location =~ s/\Q$pathinfo\E$//;

      $pmod = $papp{$location} or do {
         fancydie "Application not mounted", $location;
      };

      if ($checkdeps) {
         while (my ($path, $v) = each %{$pmod->{file}}) {
            if ((stat $path)[9] > $v->{mtime}) {
               $request->warn("reloading application $location");
               $pmod = $papp{$location} = reload_app $pmod->{path}, $pmod->{config};
               $pmod->{cb}{init}();
               $pmod->{cb}{childinit}();
               values %{$pmod->{file}}; # reset "each"-state
               last;
            }
         }
      }

      if ($pmod->{database}) {
         $PApp::SQL::DBH = PApp::SQL::connect_cached("PAPP_2", @{$pmod->{database}})
            or fancydie "error connecting to database $pmod->{database}[0]", $DBI::errstr;
      }

      $pathinfo =~ s!^/([^/]*)(?:/([^/]*))?!!;
      my $statehash = $1;
      $module = $2;

      my $state;

      if (22 == length $statehash) {
         ($userid, $prevstateid, $alternative) = unpack "VVVxxxx", $cipher_d->decrypt(PApp::X64::dec $statehash);
         $st_fetchstate->execute($prevstateid);
         $state = $st_fetchstate->fetchrow_arrayref;
      }

      if ($state) {
         *state = Storable::thaw decompress $state->[0];

         $nextid = $state->[2];

         if ($state->[1] != $userid) {
            if ($state->[1] != $state{papp}{switch_newuserid}) {
               fancydie "User id mismatch", "maybe someone is tampering?";
            } else {
               $userid = $state{papp}{switch_newuserid};
            }
         }
         delete $state{papp}{switch_newuserid};

         $st_newstateid->execute($prevstateid);
         $stateid = $st_newstateid->{mysql_insertid};
      } else {
         $st_newstateid->execute(0);
         $stateid = $st_newstateid->{mysql_insertid};

         # woaw, a new session... cool!
         %state = ();
         $alternative = 0;

         $module = $statehash if $module eq "";
         $prevstateid = 0;

         if ($request->header_in('Cookie') =~ /PAPP_1984=([0-9a-zA-Z.-]{22,22})/) {
            ($userid, undef, undef) = unpack "VVVxxxx", $cipher_d->decrypt(PApp::X64::dec $1);
         } else {
            undef $userid;
         }

         if ($userid) {
            if (get_userprefs) {
               $state{papp_visits}++;
               $state{save_prefs} = 1;
            }
         } else {
            switch_userid 0;
         }

         $module = "" unless exists $pmod->{module}{$module};
         $module = $pmod->{module}{$module}{nosession};

         $pmod->{cb}{newsession}->();

      }

      *S = \%{$state{$location}};
      %P = ($request->args, $request->content);
      %A = ();

      # enter any parameters deemed safe (import parameters);
      while (my ($k, $v) = each %P) {
         $S{$k} = $v if $pmod->{state}{import}{$k};
      }

      if ($alternative) {
         while (my($k,$v) = splice @{$state{papp}{alternative}[$alternative]}, 0, 2) {
            if (ref $k) {
               $$k = $v;
            } elsif ($k =~ s/^-//) {
               $A{$k} = $v;
            } elsif ($k =~ s/^\///) {
               $state{$k} = $v;
            } else {
               $S{$k} = $v;
            }
         }
         $alternative = 0;
         $module = delete $state{papp_module};
      }
      delete $state{papp}{alternative};

      $state{module} = "$location/$module";

      # nuke local variables that are not defined locally..
      while (my ($k, $v) = each %{$pmod->{state}{local}}) {
         delete $S{$k} unless exists $v->{$module};
      }

      # WE ARE INITIALIZED
         
      $langs = "$state{lang},".$request->header_in("Content-Language").",de,en";

      unless ($newuser) {
         save_prefs if delete $state{save_prefs};
         if ($state{papp_last_cookie} < $NOW - $cookie_reset) {
            set_cookie;
            $state{papp_last_cookie} = $NOW;
            $state{save_prefs} = 1;
         }
      }

      $pmod->{cb}{request}();
      $pmod->{module}{$module}{cb}();
      $pmod->{cb}{cleanup}();

      update_state;
   };

   my $e = $@;

   untie *STDOUT; open STDOUT, ">&1";
   untie *STDERR; open STDERR, ">&2";

   if ($e) {
      if (UNIVERSAL::isa($e, PApp::Exception)) {
         errorpage($e);
         return OK;
      } elsif ("HASH" eq ref $e) {
         update_state;
         if ($e->{internal_redirect}) {
            # we have to get rid of the old request (think POST, and Apache->content)
            $request->method_number(M_GET);
            $request->header_in("Content-Type", "");
            $request->internal_redirect($e->{internal_redirect});
            return OK;
         }
      } else {
         errorpage(new PApp::Exception error => 'Script evaluation error', info => $e);
         return OK;
      }
   } elsif ($$stderr) {
      errorpage(new PApp::Exception error => 'Output on standard error channel', info => $$stderr);
      return OK;
   }

   $request->header_out('Content-Length', length $$stdout);
   $request->send_http_header;
   $request->print($$stdout) unless $request->header_only;

   return OK;
}

# gather output to a filehandle into a string
package PApp::FHCatcher;

sub TIEHANDLE {
   my $x;
   bless \$x, shift;
}

sub PRINT {
   my $self = shift;
   $$self .= join "", @_;
   1;
}

sub PRINTF {
   my $self = shift;
   my $fmt = shift; # prototype gotcha!
   $$self .= sprintf $fmt, @_;
   1;
}

sub WRITE {
   my ($self, $data, $length) = @_;
   $$self .= $data;
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

