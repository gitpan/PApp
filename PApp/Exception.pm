=head1 NAME;

PApp::Exception - exception handling for PApp

=head1 SYNOPSIS

 use PApp::Exception;
 # to be written

=head1 DESCRIPTION

# to be written

=over 4

=cut

package PApp::Exception;

use base Exporter;

use PApp::HTML;

use utf8;

$VERSION = 0.12;
@EXPORT = qw(fancydie try catch);

no warnings;

# let's try to be careful, but brutale ausnahmefehler just rock!
sub __($) {
   eval { &PApp::__ } || $_[0];
}

use overload 
# if we use bool we are faster, BUT apache et. al. just display
# the boolean as return value.
# 2001-02-08 enabled again, maybe it works now
# 2001-02-08 no, it doesn't
# 2001-02-10 hmmm.. maybe now?
   'bool'   => sub { 1 },
   '""'     => sub { ;$_[0]{compatible} || $_[0]->as_string },
   fallback => 1,
   ;

=item local $SIG{__DIE__} = \&PApp::Exception::diehandler

_diehandler is a function suitable to be put into C<$SIG{__DIE__}> (e.g.
inside an eval). The advantage in using this function is that you get a
useful backtrace on an error (among some other information). It should be
compatible with any use of eval but might slow down evals that make heavy
use of exceptions (but these are slow anyway).

Example:

 eval {
    local $SIG{__DIE__} = \&PApp::Exception::diehandler;
    ...
 };

=cut

sub diehandler {
   unless (UNIVERSAL::isa $_[0], PApp::Exception::) {
      # wether compatible is a good idea here is questionable...
      fancydie(__"caught a die", $_[0], compatible => $_[0], skipcallers => 1);
   }
}

# internal utility function for Gimp::Fu and others
#      talking about code-reuse ^^^^^^^^ ;)
sub wrap_text {
   my $x;
   for (split /\n/, $_[0]) {
      s/\G(.{1,$_[1]})(?:\s+|$)/$1\n/gm;
      $x .= $_;
   }
   $x =~ s/[ \t\015]+$//g;
   $x;
}

# called by zero-argument "die"
sub PROPAGATE {
   push @{$_[0]{info}}, "propagated at $_[1] line $_[2]";
   $_[0];
}

=item $errobj = new param => value..

Create and return a new exception object. The object is overloaded,
stringification will call C<as_string>.

 title      exception page title (default "PApp:Exception")
 body       the exception page body
 category   the error category
 error      the error message or error object
 info       additional info (arrayref)
 backtrace  optional backtrace info
 compatible if set, stringification will only return this field

When called on an existing object, a clone of that exception object is
created and the information is extended (backtrace is being ignored,
title, info and error are extended).

=cut

sub new($$;$@) {
   my $class = shift;
   my %arg = @_;

   if (ref $class) {
      my %obj = %$class;

      $obj{backtrace} ||= delete $arg{backtrace};
      push @{$obj{info}}, @{delete $arg{info}};

      while (my ($k, $v) = each %arg) {
         $obj{$k} = $obj{$k} ? "$v\n$obj{$k}" : $v;
      }

      my ($i, $package, $filename, $line);
      do {
         $package, $filename, $line = caller $i++;
      } while ($package eq "PApp::Exception");

      push @{$obj{info}}, "propagated at $file line $line" if $package;

      bless \%obj, ref $class;
   } else {
      bless \%arg, $class;
   }
}

=item $errobj->throw

Throw the exception.

=cut

sub throw($) {
   die $_[0];
}

=item $errobj->as_string

Return the full exception information as simple text string.

=item $errobj->as_html

Return the full exception information as a fully formatted html page.

=cut

sub as_string {
   my $self = shift;
   local $@; # localize $@ as to not destroy it inadvertetly

   my $err = "\n".($self->{title} || __"PApp::Exception caught")."\n\n$self->{category}\n";
   $err .= "\n$self->{error}\n" if $self->{error};
   if ($self->{info}) {
      for (@{$self->{info}}) {
         my $info = $_;
         my $desc;

         if (ref $info) {
            $desc = " ($info->[0])";
            $info = $info->[1];
         }

         $info = wrap_text $info, 80;
         $err .= "\n".__"Additional Info"."$desc:\n$info\n";
      }
   }
   $err .= "\n".__"Backtrace".":\n$self->{backtrace}\n";
   
   $err =~ s/^/! /gm;
   $err =~ s/\0/\\0/g;

   $err;
}

sub title {
   $_[0]->{title} || __"PApp::Exception";
}

sub category {
   $_[0]->{category} || __"ERROR";
}

sub as_html {
   my $self = shift;
   my $title = sprintf __"%s (exception caught)", $self->title;

"<html>
<head>
<title>$title</title>
</head>
<body bgcolor=\"#d0d0d0\">
<blockquote>
<h1>$title</h1>".
   $self->_as_html(@_)."
</blockquote>
</body>
</html>";
}

sub _as_html($;$) {
   my $self = shift;
   my %args = @_;
   my $title = $self->title;
   my $body  = $args{body}  || $self->{body}  || "";
   my $category = escape_html ($self->category);
   my $error = escape_html $self->{error};

   $title =~ s/\n/<br>/g;
   $error =~ s/\n/<br>/g;
   
   my $err = <<EOF;
<p>
<table bgcolor='#d0d0f0' cellspacing=0 cellpadding=10 border=0>
<tr><td bgcolor='#b0b0d0'><font face='Arial, Helvetica'><b><pre>$category</pre></b></font></td></tr>
<tr><td><font color='#3333cc'>$error</font></td></tr>
</table>
EOF

   if ($self->{info}) {
      for (@{$self->{info}}) {
         my $info = $_;
         my $desc;

         if (ref $info) {
            $desc = " ($info->[0])";
            $info = $info->[1];
         }

         $info = escape_html wrap_text $info, 80;
         $err .= "<p>
<table bgcolor='#e0e0e0' cellspacing='0' cellpadding='10' border='0'>
<tr><td bgcolor='#c0c0c0'><font face='Arial, Helvetica'><b>".__"Additional Info"."$desc:</b></font></td></tr>
<tr><td><pre>$info</pre></td></tr>
</table>
";
      }
   }

   if ($self->{backtrace}) {
      my $backtrace = escape_html $self->{backtrace};
      $err .= "<p>
<table bgcolor='#ffc0c0' cellspacing='0' cellpadding='10' border='0' width='94%'>
<tr><td bgcolor='#e09090'><font face='Arial, Helvetica'><b>".__"Backtrace".":</b></font></td></tr>
<tr><td><pre>$backtrace</pre></td></tr>
</table>
";
   }

   if ($body) {
      $body = wrap_text $body, 80;
      $err .= <<EOF;
<p>
<table bgcolor='#e0e0f0' cellspacing='0' cellpadding='10' border='0'>
<tr><td><pre>$body</pre></td></tr>
</table>
EOF
   }

   $err;
}

=item fancydie $category, $error, [param => value...]

Aborts the current page and displays a fancy error box, complete
with backtrace. C<$error> should be a short error message, while
C<$additional_info> can be a multi-line description of the problem.

The rest of the function call consists of named arguments that are
transparently passed to the PApp::Exception::new constructor (see above), with the exception of:

 skipcallers  the number of calller levels to skip in the backtrace

=item fancywarn <same arguments as fancydie>

Similar to C<fancydie>, but warns only. (not exported by default).

=cut

# almost directly copied from DB, since mod_perl + 5.6 + DB is just too fragile
# obviously, this is horrible code ;->
sub papp_backtrace {
  package DB;
  local $SIG{__DIE__};

  my $start = shift;
  my($p,$f,$l,$s,$h,$w,$e,$r,$a, @a, @ret,$i);
  $start = 1 unless $start;
  for ($i = $start; ($p,$f,$l,$s,$h,$w,$e,$r) = caller($i); $i++) {
    $f = "file `$f'" unless $f eq '-e';
    $w = $w ? '@ = ' : '$ = ';
    if ($i > $start) {
       my @a = map {
          eval {
             local $_ = $_;
             s/'/\\'/g;
             s/([^\0]*)/'$1'/ unless /^-?[\d.]+$/;
             s/([\200-\377])/sprintf("M-%c",ord($1)&0177)/eg;
             s/([\0-\37\177])/sprintf("^%c",ord($1)^64)/eg;
             $_;
          } || do {
             $@ =~ s/ at \(.*$//s;
             $@;
          }
       } ($s eq "PApp::SQL::connect_cached"
          ? (@DB::args[0,1], "<user>", "<pass>", @DB::args[4,5]) # nur loeschwasser
          : @DB::args);
       $a = $h ? '(' . join(', ', @a) . ')' : '';
       $e =~ s/\n\s*\;\s*\Z// if $e;
       $e =~ s/[\\\']/\\$1/g if $e;
       if ($r) {
         $s = "require '$e'";
       } elsif (defined $r) {
         $s = "eval '$e'";
       } elsif ($s eq '(eval)') {
         $s = "eval {...}";
       }
       push @ret, "$w&$s$a from $f line $l";
    } else {
       push @ret, "$w&$s$a called from $f line $l";
    }
    last if $DB::signal;
  }
  return @ret;
}

sub _fancyerr {
   my $category = shift;
   my $error = shift;
   my $info = [];
   my $backtrace;
   my @arg;
   my $skipcallers = 2;

   while (@_) {
      my $arg = shift;
      my $val = shift;
      if ($arg eq "skipcallers") {
         $skipcallers += $val;
      } elsif ($arg eq "info") {
         push @$info, $val;
      } else {
         push @arg, $arg, $val;
      }
   }

   for my $frame (papp_backtrace($skipcallers)) {
      $frame =~ s/  +/ /g;
      $frame = wrap_text $frame, 80;
      $frame =~ s/\n/\n    /g;
      $backtrace .= "$frame\n";
   }

   s/\n+$//g for @$info;

   my $class = PApp::Exception::;

   ($class, $error)    = ($error,     undef) if UNIVERSAL::isa $error,    PApp::Exception::;
   ($class, $category) = ($category,  undef) if UNIVERSAL::isa $category, PApp::Exception::;

   $class->new(
      backtrace => $backtrace,
      category  => $category,
      error     => $error,
      info      => $info,
      @arg,
   );
}

sub fancydie {
   &_fancyerr->throw;
}

sub fancywarn {
   warn &_fancyerr;
}

=item vals = try BLOCK error, args...

C<eval> the given block (using a C<_diehandler>, C<@_> will contain
useless values and the context will always be array context). If no error
occurs, return, otherwise execute fancydie with the error message and the
rest of the arguments (unless they are C<catch>'ed).

=item catch BLOCK args...

Not yet implemented. If used as an argument to C<try>, execute the block when
an error occurs.

=cut

sub try(&;@) {
   my @r = eval {
      local $SIG{__DIE__} = \&_diehandler;
      &{+shift};
   };
   if ($@) {
      my $err = shift;
      fancydie $err, $@, @_;
   }
   wantarray ? @r : $r[-1];
}

sub catch(&;%) {
   fancydie "catch not yet implemented";
}

=item $exc->errorpage

This method is being called by the PApp runtime whenever there is no handler
for it. It should (depending on the $PApp::onerr variable and others!) display
an error page for the user. Better overwrite the following methods, not this one.

=item $exc->ep_save

=item $html = $exc->ep_fullinfo

=item $html = $exc->ep_shortinfo

=item $html = $exc->ep_login

=item $html = $exc->ep_wrap(...)

=cut

sub _clone {
   eval {
      require Storable; # should use Clone some day
      local $Storable::forgive_me = 1;
      Storable::dclone($_[0]);
   } || "$_[1]: $@";
}

sub _clone_request {
   my $r = $PApp::request;
   +{
      eval {
         time        => time,
         method      => $r->method,
         protocol    => $r->protocol,
         hostname    => $r->hostname,
         uri         => $r->uri,
         filename    => $r->filename,
         path_info   => $r->path_info,
         args        => $r->query_string,
         headers_in  => { $r->headers_in },
         remote_logname => $r->get_remote_logname,
         remote_addr => $r->connection->remote_addr,
         local_addr  => $r->connection->local_addr,
         http_user   => $r->connection->user,
         http_auth   => $r->connection->auth_type,
      }
   }
}

sub errorpage {
   package PApp;

   my $self = shift;
   my $onerr = exists $papp->{onerr} ? $papp->{onerr} : $PApp::onerr;
   my @html;

   content_type("text/html", "*");

   $self->{save} = {
      output    => $output,
      arguments => PApp::Exception::_clone(\%arguments, "unable to clone arguments"),
      params    => PApp::Exception::_clone(\%P,         "unable to clone params"),
      state     => PApp::Exception::_clone(\%state,     "unable to clone state"),
      userid    => $userid,
      stateid   => $stateid,
      prevstateid => $prevstateid,
      alternative => $alternative,
      request   => PApp::Exception::_clone_request,
   };

   $onerr ||= "sha";

   push @html, $self->ep_save      if $onerr =~ /s/i;
   push @html, $self->ep_shortinfo if $onerr =~ /h/i;
   push @html, $self->ep_fullinfo  if $onerr =~ /v/i;
   push @html, $self->ep_login     if $onerr =~ /a/i;

   $PApp::output = $self->ep_wrap (@html);
}

sub ep_save {
   my $self = shift;
   __"[saving is not currently implemented]";
}

sub ep_shortinfo {
   my $self = shift;
   $self->category;
}

sub ep_fullinfo {
   my $self = shift;
   $self->_as_html;
}

sub ep_login {
   my $self = shift;
   eval {
      $PApp::papp_main->slink(__"[Login/View this error]", "error", exception => $self);
   } or __"[unable to enter error browser at this time]";
}

sub ep_wrap {
   my $self = shift;
   my $title = sprintf __"%s (exception caught)", $self->title;
   "<html>
    <head>
    <title>$title</title>
    </head>
    <body bgcolor=\"#d0d0d0\">
    <blockquote>
    <h1>$title</h1>".
   (join "", map "<p>$_</p>", @_).
   "</blockquote></body></html>";
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

