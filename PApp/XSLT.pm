=head1 NAME

PApp::XSLT - wrapper for an XSLT implementation

=head1 SYNOPSIS

 use PApp::XSLT;
 # to be written

=head1 DESCRIPTION

The PApp::XSLT module is more or less a wrapper around an unnamed XSLT
implementation (currently XML::Sablotron, but that might change).

# to be written

=over 4

=cut

package PApp::XSLT;

$VERSION = 0.12;

no bytes;

use Convert::Scalar ();

use PApp::Exception;

our $sablo;
our $curobj;
our $curerr;

=item new PApp::XSLT parameter => value...

Creates a new PApp::XSLT object with the specified behaviour. All
parameters are optional.

 stylesheet     see the C<stylesheet> method.
 get_<scheme>   see the C<scheme_handler> method.

=cut

sub new($;%) {
   my $class = shift,
   my %args = @_;
   my $self = bless {}, $class;

   while (my ($k, $v) = each %args) {
      $self->scheme_handler($1, $v) if $k =~ /^get_(.*)$/;
   }

   $self->stylesheet($args{stylesheet}) if defined $args{stylesheet};

   unless ($sablo) { # a singleton object
      local $curobj = $self;
      my $proxyobj = bless [], PApp::XSLT::Handler::;
      require XML::Sablotron;
      $sablo = XML::Sablotron->new;
      $sablo->RegHandler(0, $proxyobj);
      $sablo->RegHandler(1, $proxyobj);
   }

   $self;
}

=item $old = $xslt->stylesheet([stylesheet-uri])

Set the stylesheet to use for later transofrmation requests by specifying
a uri. The only supported scheme is currently C<data:,verbatim xml
stylesheet text> (the comma is not a typoe, see rfc2397 on why this is
the most compatible form to the real data: scheme ;).

If the stylesheet is a code reference (or any reference), it is executed
for each invocation and should return the actual stylesheet to use.

It always returns the current stylesheet.

=cut

sub stylesheet($;$) {
   my $self = shift;
   my $ss = shift;
   if (ref $ss) {
      $self->{ss} = $ss;
   } elsif (defined $ss) {
      my ($scheme, $rest) = split /:/, $ss, 2;
      $self->{ss} = $self->SHGetAll(undef, $scheme, $rest);
   }
   $self->{ss};
}


=item $old = $xslt->scheme_handler($scheme[, $handler])

Set a handler for the given uri scheme.  The handler will be called with
the xslt object, the scheme name and the rest of the uri and is expected
to return the whole document, e.g.

   $xslt->set_handler("http", sub {
      my ($self, $scheme, $uri) = @_;
      return "<dokument>text to be returned</dokument>";
   });

might be called with (<obj>, "http", "www.plan9.de/").  Hint: this
function can easily be abused to feed data into a stylesheet dynamically.

When the $handler argument is C<undef>, the current handler will be
deleted. If it is missing, nothing happens (only the old handler is
returned).

=cut

sub scheme_handler($$;$) {
   my $self = shift;
   my $scheme = shift;
   my $old = $self->{get}{$scheme};
   if (@_) {
      delete $self->{get}{$scheme};
      $_[0] and $self->{get}{$scheme} = shift;
   }
   $old;
}

for my $method (qw(SHGetAll MHError SHOpen)) {
   *{"PApp::XSLT::Handler::$method"} = sub {
      shift;
      $curobj->$method(@_);
   };
}

# for speed, these two methods get shortcutted
sub PApp::XSLT::Handler::MHLog {}
sub PApp::XSLT::Handler::MHMakeCode { $_[4] }

#sub MHLog($$$$;@) {
#   my ($self, $processor, $code, $level, @fields) = @_;
#   warn "PApp::XSLT<$code,$level> @fields\n";
#}
#
#sub MHMakeCode {
#   my ($self, $processor, $severity, $facility, $code) = @_;
#   warn "MHMake @_\n";#d#
#   $code;
#}

sub MHError($$$$;@) {
   my ($self, $processor, $code, $level, @fields) = @_;
   unless ($curerr) {
      my $msgtype = "error";
      my $uri;
      my $line;
      my $msg = "unknown error";
      my @other;
      for (@fields) {
         if (my ($k, $v) = split /:/, $_, 2) {
            if ($k eq "msgtype") {
               $msgtype = $v;
            } elsif ($k eq "URI") {
               $uri = $v;
            } elsif ($k eq "msg") {
               $msg = $v;
            } elsif ($k eq "line") {
               $line = $v;
            } elsif ($k eq "module") {
               # always Sablotron
            } elsif ($k !~ /^(?:code)$/) {
               push @other, "$k=$v";
            }
         }
      }
      $curerr = [ $uri,
         "$msgtype: ".
         ($uri ? $uri : "").
         ($line ? " line $line" : "").
         ": $msg".
         (@other ? " (@other)" : ""),
      ];
   }
}

sub SHOpen {
   my ($self, $processor, $scheme, $rest) = @_;
   $self->MHError($processor, 1, 3,
         "msgtype:error",
         "code:1",
         "module:PApp::XSLT",
         "URI:$scheme:$rest",
         "msg:SHOpen unsupported",
   );
   undef;
}

sub SHGet {
   return "]]>\"'<<&&"; # certainly cause a parse error ;->
}

sub SHPut { }
sub SHClose { }

sub SHGetAll($$$$) {
   my ($self, $processor, $scheme, $rest) = @_;
   if ($self->{get}{$scheme}) {
      my $dok = eval { $self->{get}{$scheme}($self, $scheme, $rest) }
                || ""; # do not try SHOpen, _pleeease_
      if ($@) {
         $self->MHError($processor, 1, 3,
               "msgtype:error",
               "code:1",
               "module:PApp::XSLT",
               "URI:$scheme:$rest",
               "msg:scheme handler evaluation error '$@'",
         );
      } else {
         return $dok;
      }
   } elsif ($scheme eq "data") {
      return substr $rest, 1;
   } else {
      $self->MHError($processor, 1, 3,
            "msgtype:error",
            "code:1",
            "module:PApp::XSLT",
            "URI:$scheme:$rest",
            "msg:unsupported uri scheme",
      );
   }
   return "]]>\"'<<&&"; # certainly cause a parse error ;->
}

=item $xslt->apply(document-uri[, param => value...])

Apply the document (specified by the given document-uri) and return it as
a string. Optional arguments set the named global stylesheet parameters.

=cut

sub apply($$;@) {
   my $self = shift;
   my ($scheme, $rest) = split /:/, shift, 2;
   $self->apply_string($self->SHGetAll(undef, $scheme, $rest), @_);
}

=item $xslt->apply_string(xml-doc[, param => value...])

The same as calling the C<apply>-method with the uri C<data:,xml-doc>, i.e.
this method applies the stylesheet to the string.

=cut

sub apply_string($$;@) {
   local $curobj = shift;
   local $curerr;
   my $source = shift;
   $sablo->ClearError;
   my $ss = ref $curobj->{ss} ? $curobj->{ss}->() : $curobj->{ss};
   Convert::Scalar::utf8_off($ss);
   $sablo->RunProcessor(
                        "arg:/template",
                        "arg:/data",
                        "arg:/result",
                        \@_,
                        [
                           template => $ss,
                           data => $source,
                        ],
                       );
   if ($curerr || $@) {
      require PApp::Util;
      fancydie "error during stylesheet processing", $curerr->[1] || $@,
               $curerr->[0] ne "arg:/template" ? (info => ["arg:/data"     => PApp::Util::format_source($source)]) : (),
               $curerr->[0] ne "arg:/data"     ? (info => ["arg:/template" => PApp::Util::format_source($ss    )]) : (),
              ;
   } else {
      $source = $sablo->GetResultArg("result");
   }
   $sablo->FreeResultArgs;
   Convert::Scalar::utf8_on($source); # yes, perl, it's already unicode
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

