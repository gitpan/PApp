package PApp::Exception;

require Exporter;

use PApp::HTML;

@ISA = qw(Exporter);
$VERSION = 0.03;
@EXPORT = qw(fancydie);

sub new($$;$@) {
   my $class = shift;
   if (UNIVERSAL::isa $_[0], __PACKAGE__) {
      $_[0];
   } else {
      bless { @_ }, $class;
   }
}

sub throw {
   die shift;
}

sub as_string {
   my $self = shift;
   "$self->{error}\n$self->{info}\n$self->{backtrace}\n";
}

sub as_html($;$) {
   my $self = shift;
   my %args = @_;
   my $title = $args{title} || $self->{title} || "PApp::Exception";
   my $body  = $args{body}  || $self->{body}  || "";
   my $error = escape_html $self->{error};
   my $err = <<EOF;
<html>
<head>
<title>$title (exception caught)</title>
</head>
<body bgcolor=\"#d0d0d0\">
<blockquote>
<h1>$title (exception caught)</h1>

<p>
<table bgcolor=\"#d0d0f0\" cellspacing=0 cellpadding=10 border=0>
<tr><td bgcolor=\"#b0b0d0\"><font face=\"Arial, Helvetica\"><b>ERROR:</b></font></td></tr>
<tr><td><h2><font color=\"#3333cc\">$error</font></h2></td></tr>
</table>
EOF

   if ($self->{info}) {
      my $info = escape_html $self->{info};
      $err .= <<EOF;
<p>
<table bgcolor=\"#e0e0e0\" cellspacing=0 cellpadding=10 border=0>
<tr><td bgcolor=\"#c0c0c0\"><font face=\"Arial, Helvetica\"><b>Additional Info:</b></font></td></tr>
<tr><td><pre>$info</pre></td></tr>
</table>
EOF
   }

   if ($body) {
      $err .= <<EOF;
<p>
<table bgcolor=\"#e0e0f0\" cellspacing=0 cellpadding=10 border=0>
<tr><td><pre>$body</pre></td></tr>
</table>
EOF
   }

   if ($self->{backtrace}) {
      my $backtrace = escape_html $self->{backtrace};
      $err .= <<EOF;
<p>
<table bgcolor=\"#ffc0c0\" cellspacing=0 cellpadding=10 border=0 width="94%">
<tr><td bgcolor=\"#e09090\"><font face=\"Arial, Helvetica\"><b>Backtrace:</b></font></td></tr>
<tr><td><pre>$backtrace</pre></td></tr>
</table>
EOF
   }

   $err . <<EOF
</blockquote>
</body>
</html>
EOF
}

use overload 
   '""'   => \&as_string,
   'bool' => sub { 1 };

# internal utility function for Gimp::Fu and others
#      talking about code-reuse ^^^^^^^^ ;)
sub wrap_text {
   my $x=$_[0];
   $x=~s/\G(.{1,$_[1]})(\s+|$)/$1\n/gm;
   $x=~s/[ \t\r\n]+$//g;
   $x;
}

=item fancydie $error, $additional_info

Aborts the current page and displays a fancy error box, complete
with backtrace.  C<$error> should be a short error message, while
C<$additional_info> can be a multi-line description of the problem.

=cut

sub fancydie {
   my $error = shift;
   my $info = shift;
   my $backtrace;

   $info =~ s/\n+$//g;

   require DB;
   @PApp::Exception::DB::ISA = 'DB';
   for my $frame (PApp::Exception::DB->backtrace) {
      $frame =~ s/  +/ /g;
      $frame = wrap_text $frame, 80;
      $frame =~ s/\n/\n     /g;
      $backtrace .= "$frame\n";
   }

   (new PApp::Exception error => $error, info => $info, backtrace => $backtrace, @_)->throw;
}

1;

