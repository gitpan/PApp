=head1 NAME

PApp::XML - pxml sections and more

=head1 SYNOPSIS

 use PApp::XML;
 # to be written

=head1 DESCRIPTION

The PApp::XML module manages XML templates containing papp xml directives
and perl code similar to phtml sections. Together with stylesheets
(L<XML::XSLT>) this can be used to almost totally seperate content from
layout. Image a database containing XML documents with customized tags.
A stylesheet can then be used to transofrm this XML document into html +
special pappxml directives that can be used to create links etc...

# to be written

=over 4

=cut

package PApp::XML;

$VERSION = 0.05;

=item new PApp::XML parameter => value...

Creates a new PApp::XML template object with the specified behaviour. It
can be used as an object factory to create new C<PApp::XML::Template>
objects.

 special	a hashref containing special => coderef pairs. If a special
                is encountered, the given coderef will be compiled in
                instead. If a reference to a coderef is given, the coderef
                will be called during parsing and the resulting string will
                be added to the compiled subroutine
 html           html output mode enable flag (NYI)

=cut

use PApp qw(echo sublink slink current_locals);

sub new($;%) {
   my $class = shift,
   my %args = @_;
   my $self = bless {}, $class;

   $self->{attr} = delete $args{attr} || {};
   $self->{html} = delete $args{html} || {};
   $self->{special} = {
      slink => sub {
         my ($attr, $content) = @_;
         my %attr = %$attr;
         my $sublink = delete $attr{sublink};
         my @args = delete $attr{module};
         while (my ($k, $v) = each %attr) {
            $k =~ s/^_/-/;
            push @args, $k, $v;
         }
         echo $sublink eq "yes"
            ? sublink [current_locals], $content, @args
            : slink $content, @args;
      },
      %{delete $args{special} || {}},
   };

   $self;
}

=item $pappxml->dom2template($dom, {special}, key => value...)

Compile the given DOM into a C<PApp::XML::Template> object and returns
it. An additional set of specials only used to parse this dom can be
passed as a hashref (this argument is optional). Additional key => value
pairs will be added to the template's attribute hash. The template will be
evaluated in the caller's package (e.g. to get access to __ and similar
functions).

On error, nothing is returned. Use the C<error> method to get more
information about the problem.

In addition to the syntax accepted by C<PApp::Parser::phtml2perl>, this
function evaluates certain XML Elements (please note that I consider the
"pappxml" namespace to be reserved):

 pappxml:special _special="special-name" attributes...
   
   Evaluate the special with the name given by the attribute C<_special>
   after evaluating its content. The special will receive two arguments:
   a hasref with all additional attributes and a string representing an
   already evaluated code fragment.

=begin comment

 attr           a hasref with attribute => value pairs. These attributes can
                later be quieried and set using the C<attr> method.

=end comment

=cut
                
sub dom2template($$;%) {
   my $self = shift;
   my $dom = shift;
   my $temp = bless {
      attr => {@_},
   }, PApp::XML::Template::;
   my $package = (caller)[0];

   $temp->{code} = $temp->_dom2sub($dom, $self, $package);

   delete $temp->{attr}{special};

   if ($temp->{code}) {
      $temp;
   } else {
      # error
      ();
   }
}

=item $err = $pappxml->error

Return infortmation about an error as an C<PApp::Exception> object
(L<PApp::Exception>).

=cut

sub error {
   my $self = shift;
   $self->{error};
}

package PApp::XML::Template;

use PApp::Parser ();
use XML::DOM;

sub __dom2sub($) {   
   my $node = $_[0]->getFirstChild;

   while ($node) {
      my $type = $node->getNodeType;

      if ($type == TEXT_NODE || $type == CDATA_SECTION_NODE) {
         $_res .= $node->toString;
      } elsif ($type == ELEMENT_NODE) {
         my $name = $node->getTagName;
         my %attr;
         {
            my $attrs = $node->getAttributes;
            for (my $n = $attrs->getLength; $n--; ) {
               my $attr = $attrs->item($n);
               $attr{$attr->getName} = $attr->getValue;
            }
         }
         if (substr($name, 0, 8) eq "pappxml:") {
            if ($name eq "pappxml:special") {
               my $name = delete $attr{_special};
               my $sub = $_self->{attr}{special}{$name} || $_factory->{special}{$name};

               if (defined $sub) {
                  my $idx = @_local;
                  push @_local, $sub;
                  push @_local, \%attr;
                  push @_local, $_self->_dom2sub($node, $_factory, $_package);
                  $_res .= '<:
                     $_dom2sub_local->['.($idx).'](
                           $_dom2sub_local->['.($idx+1).'],
                           capture { $_dom2sub_local->['.($idx+2).']() },
                           $_dom2sub_self,
                     )
                  :>';
               } else {
                  $_res .= "&lt;&lt;&lt; undefined special '$name' containing '";
                  __dom2sub($node);
                  $_res .= "' &gt;&gt;&gt;";
               }
            } elsif ($name eq "pappxml:unquote") {
               my $res = do {
                  local $_res;
                  __dom2sub($node);
                  $_res;
               };
               $res =~ s{&([^;]+);}{
                    { gt => '>', lt => '<', amp => '&', quot => '"', apos => "'" }->{$1}
               }ge;
               $_res .= $res;
            } else {
               $_res .= "&lt;&lt;&lt; undefined pappxml element '$name' containing '";
               __dom2sub($node);
               $_res .= "' &gt;&gt;&gt;";
            }
         } else {
            $_res .= "<$name";
            while (my ($k, $v) = each %attr) {
               # we prefer single quotes, since __ and N_ do not
               $v =~ s/'/&apos;/g;
               $_res .= " $k='$v'";
            }
            my $content = do {
               local $_res;
               __dom2sub($node);
               $_res;
            };
            if ($content ne "") {
               $_res .= ">$content</$name>";
            } elsif ($_factory->{html}) {
               if ($name =~ /^br|p|hr|img|meta|base|link$/i) {
                  $_res .= ">";
               } else {
                  $_res .= "></$name>";
               }
            } else {
               $_res .= "/>";
            }
         }
      }
      $node = $node->getNextSibling;
   }
}

sub _dom2sub($$$$) : locked {
   local $_self = shift;
   local $_dom = shift;
   local $_factory = shift;
   local $_package =  shift;

   local @_local;
   local $_res;
   __dom2sub($_dom);

   my $_dom2sub_local = \@_local;
   my $_dom2sub_self = $_self;
   my $_dom2sub_str = <<EOC;
package $_package;
sub {
#line 1 \"anonymous PApp::XML::Template\"
${\(PApp::Parser::phtml2perl($_res))}
}
EOC
   my $self = $_self;
   my $sub = eval $_dom2sub_str;

   if ($@) {
      $_factory->{error} = new PApp::Exception error => $@, info => $_dom2sub_str;
      return;
   } else {
      delete $_factory->{err};
      return $sub;
   }
}

=item $template->attr(key, [newvalue])

Return the attribute value for the given key. If C<newvalue> is given, replaces
the attribute and returns the previous value.

=cut

sub attr($$;$) {
   my $self = shift;
   my $key = shift;
   my $val = $self->{attr}{$key};
   $self->{attr}{$key} = shift if @_;
   $val;
}

=item $template->print

Print (and execute any required specials). You cna capture the output
using the C<PApp::capture> function.

=cut

sub print($) {
   shift->{code}();
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

