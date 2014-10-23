=head1 NAME

PApp::CGI - use PApp in a CGI environment

=head1 SYNOPSIS

  use PApp::CGI;

  # initialize request and do initialization
  init PApp::CGI and PApp::config_eval {
     configure PApp ...;
     $handler = mount_app "admin";
     configured PApp;
  };

  # then for each request do
  &$handler;

=head1 DESCRIPTION

This module can be used to run PApp applications without Apache/mod_perl,
e.g. using L<CGI::SpeedyCGI>.  The startup-penalty for PApp is immense
(a second or so) and is dominated by compilation time, so while PApp is
usable with "pure" CGI in some applicaitons a CGI-Accelerator is certainly
recommended.

The C<$PApp::request>-object (as returned by new <PApp::CGI::Request>) is
mostly compatible to L<Apache>, except for missing methods (which could be
added quite easily on request).

=cut

package PApp::CGI;

use PApp ();
use PApp::Exception;
use PApp::HTML ();
use Exporter;

BEGIN {
   @ISA = (PApp::Base::);
   unshift @PApp::ISA, __PACKAGE__;
   $VERSION = 0.122;
}

=head2 FUNCTIONS

=over 4

=cut

sub kill_self {
   # are we running under speedycgi?
   # if yes, need to shutdown this backend process completely
   # alternatively one might want to "unconfigure" PApp.
   eval {
      require CGI::SpeedyCGI;
      my $sp = new CGI::SpeedyCGI;
      $sp->setopt('MAXRUNS', 1);
   };
   exit(1);
}

sub config_error {
   my $self = shift;
   my $exc = shift;
   $PApp::request ||= new PApp::CGI::Request;
   PApp::handle_error($exc);
   PApp::flush_snd_length;

   kill_self; # going on with processing is not safe
}

=back

=head2 THE PApp::CGI CLASS

This class only contains one user-visible-method: C<init>.

=over

=cut

*PApp::OK     = sub () { 99 };

=item $first = init PApp::CGI [@args]

This method should be called once for each request, to initialize the
request structure. It also checks wether this is the first request served
by this process and returns true. For all subsequent requests it returns
false. This can be used to configure PApp once.

=cut

my $once;

sub init {
   shift; # $class
   $PApp::request = new PApp::CGI::Request @_;
   !$once++;
}

sub configure {
   my $self = shift;
   $self->SUPER::configure(@_);
}

sub interface {
   qw(CGI 0.01);
}

sub mount {
   my $self = shift;
   my $papp = shift;
   my %args = @_;

   $self->SUPER::mount($papp, %args);
}

sub mount_appset {
   my $self = shift;
   my $appset = shift;
   my %app;

   for ($self->SUPER::mount_appset($appset, @_)) {
      $app{$_->{name}} = $_;
   }

   sub {
      package PApp;
      local $location = $request->{name};
      local $pathinfo = $request->{path_info};
      local $papp;
      if ($pathinfo =~ s/^\/([a-zA-Z0-9-_]+)// and $papp = $app{$1}) {
         $location .= "/$1";
         _handler;
      } else {
         $output_p = 0;
         content_type "text/html", "*";
         $$routput =
            "<html><head><title>PApp::Appset $appset</title></head><body>" .
            (join "", map {
               "<a href=".(PApp::HTML::escape_attr("$location/$_")).">$_</a><br />"
            } sort keys %app).
            "</body></html>";
         PApp::flush_cvt;
         PApp::flush_snd_length;
         undef $output_p;
      }
   }
}

sub mount_app {
   my $self = shift;
   my $app = shift;
   my %args = @_;

   $app = $self->SUPER::mount_app($app, %args);

   sub {
      package PApp;
      local $location = $request->{name};
      local $pathinfo = $request->{path_info};
      local $papp = $app;
      _handler;
   }
}

sub configured {
   my $self = shift;
   $self->SUPER::configured(@_);
}

=back

=head2 THE PApp::CGI::Request CLASS

This class implements the C<$request> object required by a PApp
handler. The methods in this class are mostly identical to the methods
supported by the L<Apache> module (but should nevertheless be documented).

=over 4

=cut

package PApp::CGI::Request;

use PApp::HTML ();
use Carp ();

sub warn {
   print STDERR $_[1];
}

sub new {
   my $class = shift;

   if ($ENV{GATEWAY_INTERFACE} =~ /^CGI\//) {
      $class = bless {
         document_root => $ENV{DOCUMENT_ROOT},
         path_info     => $ENV{PATH_INFO},
         query_string  => $ENV{QUERY_STRING},
         #uri           => $ENV{SCRIPT_URL} || "$ENV{SCRIPT_NAME}$ENV{PATH_INFO}",
         name          => $ENV{SCRIPT_NAME},
         method        => $ENV{REQUEST_METHOD},
         filename      => $ENV{PATH_TRANSLATED},
         server_admin  => $ENV{SERVER_ADMIN},
         server_hostname=>$ENV{SERVER_NAME},
         server_admin  => $ENV{SERVER_ADMIN},
         protocol      => $ENV{SERVER_PROTOCOL},
         headers_in    => {
            "Content-Type"	=> $ENV{CONTENT_TYPE},
            "Content-Length"	=> $ENV{CONTENT_LENGTH},
            # should just copy ALL HTTP_*-headers
            "Accept-Language"	=> $ENV{HTTP_ACCEPT_LANGUAGE},
            "Accept"		=> $ENV{HTTP_ACCEPT},
            "Accept-Charset"	=> $ENV{HTTP_ACCEPT_CHARSET},
            "Accept-Encoding"	=> $ENV{HTTP_ACCEPT_ENCODING},
            "Cookie"		=> $ENV{HTTP_COOKIE},
            "Host"		=> $ENV{HTTP_HOST},
            "Connection"	=> $ENV{HTTP_CONNECTION},
            "User-Agent"	=> $ENV{HTTP_USER_AGENT},
         },
         connection    => (bless {
            remote_host		=> $ENV{REMOTE_HOST},
            remote_ip		=> $ENV{REMOTE_ADDR},
            remote_port		=> $ENV{REMOTE_PORT},
            local_ip		=> $ENV{SERVER_ADDR},
            local_port		=> $ENV{SERVER_PORT},
            remote_logname	=> $ENV{REMOTE_IDENT},
            auth_type		=> $ENV{AUTH_TYPE},
            user		=> $ENV{REMOTE_USER},
         }, PApp::CGI::Connection),
         @_,
      }, $class;
   } else {
      die "cgi environment currently required\n";
   }

   $class;
}

BEGIN {
   for my $field (qw(
      filename path_info uri header_only method
      document_root query_string connection filename
      server_admin server_hostname
      protocol
   )) {
      *{$field} = sub {
         @_ > 1 ? $_[0]->{$field} = $_[1] : $_[0]->{$field};
      };
   }
}

sub get_remote_host {
   $_[0]{connection}->remote_host;
}

sub get_remote_logname {
   $_[0]{connection}->remote_logname;
}

sub hostname {
   $_[0]->{headers_in}{Host};
}

sub port {
   $_[0]->{connection}{local_port};
}

sub headers_in {
   $_[0]{headers_in};
}

sub header_in {
   @_ > 2 ? $_[0]{headers_in}{$_[1]}  = $_[2] : $_[0]{headers_in}{$_[1]};
}

sub header_out {
   @_ > 2 ? $_[0]{headers_out}{$_[1]} = $_[2] : $_[0]{headers_out}{$_[1]};
}

sub content_type {
   splice @_, 1, 0, "Content-Type";
   goto &header_out;
}

sub status {
   my $self = shift;
   $self->{headers_out}{Status} = $_[0];
}

sub args {
   my $self = shift;
   $self->{args} = $_[0] if @_;
   $self->{args};
}

sub content {
   my $self = shift;
   if ($self->{headers_in}{"Content-Type"} eq "application/x-www-form-urlencoded") {
      my $buf;
      $self->read($buf, $self->{headers_in}{"Content-Length"}, 0);
      $buf;
   } else {
      ();
   }
}

sub read {
   CORE::read STDIN,
              $_[1], 
              ($_[2] > $_[0]->{headers_in}{"Content-Length"}
                  ? $_[0]->{headers_in}{"Content-Length"}
                  : $_[2]),
              $_[3];
}

sub log_reason {
   my ($self, $message, $filename) = @_;
   $self->warn("$filename: $message\n");
}

sub log_error {
   my ($self, $message) = @_;
   $self->warn("$message\n");
}

sub as_string {
   my $self = shift;
   require PApp::Util;
   PApp::Util::dumpval($self);
}

sub send_http_header {
   my $self = shift;

   if ($self->{nph}) {
      # nph scripts are often a bad idea
      my $status = delete $self->{headers_out}{Status} || 200;
      print "HTTP/1.0 $status Status $status\015\012Connection: close\015\012";
   }
   while (my ($h, $v) = each %{$self->{headers_out}}) {
      print "$h: $v\015\012";
   }
   print "\015\012";
}

sub print {
   use bytes;
   my $self = shift;
   print @_;
}

=item internal_redirect "relative-url"

This expands the relative url into an absolute one and generates an
I<external> redirect.

=cut

sub internal_redirect {
   my $self = shift;
   my $uri = shift;
   # it ain't pretty, baby, but can't you feel the rythm?
   if (defined $ENV{SSL_PROTOCOL}) {
      $uri = "https://" .
             ($self->{headers_in}{Host}
              || $self->{server_hostname} .
                    ($self->{connection}{server_port} != 443
                        ? ":$self->{connection}{local_port}"
                        : "")).
             $uri;
   } else {
      $uri = "http://" .
             ($self->{headers_in}{Host}
              || $self->{server_hostname} .
                    ($self->{connection}{server_port} != 80
                        ? ":$self->{connection}{local_port}"
                        : "")).
             $uri;
   }
   PApp::_gen_external_redirect $uri;
}

=item send_fd $filehandle

Reads file/pipe/whatever specified with C<$filehandle> (not a fd!) and
outputs it until it is exhausted.

=cut

sub send_fd {
   my ($self, $fh, $buf, $len) = @_;
   while() {
      $len = sysread $fh, $buf, 65536;
      if (defined $len) {
         return unless $len;
         syswrite STDOUT, $buf, $len;
      } else {
         require Errno;
         die "unable to send $fh: $!" if $! != Errno::EINTR;
      }
   }
}

package PApp::CGI::Connection;

=back

=head2 THE PApp::CGI::Connection CLASS

This class implements the connection object returned by
C<$request->conenction).  The methods in this class are mostly identical
to the methods supported by the conenction object in the L<Apache> module
(but should nevertheless be documented).

=over 4

=cut

BEGIN {
   for my $field (qw(
      remote_host remote_ip remote_logname user
      auth_type
   )) {
      *{$field} = sub {
         @_ > 1 ? $_[0]->{$field} = $_[1] : $_[0]->{$field};
      };
   }
}

sub fileno { 0 }

sub local_addr {
   my $self = shift;
   require Socket;
   Socket::sockaddr_in(Socket::inet_aton($self->{local_ip}), $self->{local_port});
}

sub remote_addr {
   my $self = shift;
   require Socket;
   Socket::sockaddr_in(Socket::inet_aton($self->{remote_ip}), $self->{remote_port});
}

# aborted

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

