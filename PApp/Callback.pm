=head1 NAME

PApp::Callback - a workaround for the problem of nonserializable code.

=head1 SYNOPSIS

 use PApp::Callback;

 my $function = register_callback BLOCK/CODEREF/FUNCNAME, "key => value...";
 my $cb = $function->refer([args...]);

 &$cb;

=head1 DESCRIPTION

HIGHLY EXPERIMENTAL MODULE, INDEED!

The problem: Code is unserializable (at the moment, but it will probably never be
efficient to serialize code).

The workaround (B<not> the solution): This class can be used to create
serializable callbacks (or "references"). You first have to register all
possible callback functions (in every process, and before you try to call
callbacks). Future versions might allow loading files or strings with the
function definition.

=over 4

=cut

package PApp::Callback;

require 5.006;

require Exporter;

@ISA = qw(Exporter);
$VERSION = 0.07;
@EXPORT = qw(register_callback);

=item register_callback functiondef, key => value...

Registers a function (preferably at program start) and returns a callback
object that can be used to create callable but serializable objects.

If C<functiondef> is a string it will be interpreted as a function name in
the callers package (unless it conatins '::'). Otherwise you should use a
"name => <funname>" argument to uniquely identify the function. If it is
omitted the filename and linenumber will be used, but that is fragile.

Examples:

 my $func = register_callback {
               print "arg1 is 5 $_[0], arg2 is 7 $_[1]\n";
            }, name => "toytest_myfunc1";

 my $cb = $func->refer(5);
 # experimental alternative: $func->(5)

 # ... serialize and deserialize $cb using Data::Dumper, Storable etc..

 # should call the callback with 5 and 7
 $cb->(7);

=cut

our %registry;

sub register_callback(&;@) {
   shift if $_[0] eq __PACKAGE__;
   my ($package, $filename, $lineno) = caller;
   my $id;
   my $code = shift;
   my %attr = @_;

   if (ref $code) {
      $id = $attr{name} ? "I$attr{name}" : "A$filename:$lineno";
      $registry{$id} = $code;
   } else {
      $code = $package."::$code" unless $code =~ /::/;
      $id = "F$code";
      $registry{$id} = sub { goto &$code }
   }

   my $self = bless {
      'package' => $package,
      filename  => $filename,
      id        => $id,
   }, __PACKAGE__;

   $self;
}

=item $cb = $func->refer([args...])

Create a callable object (a code reference). The callback C<$cb> can
either be executed by calling the C<call> method or by treating it as a
code reference, e.g.:

 $cb->call(4,5,6);
 $cb->(4,5,6);
 &$cb;

It will behave as if the original registered callback function would be
called with the arguments given to C<register_callback> first and then the
arguments given to the C<call>-method.

=cut

sub refer($;@) {
   my $self = shift;

   bless {
      func => $self,
      args => \@_,
   }, PApp::Callback::Function::;
}

use overload
   fallback => 1,
   '&{}' => sub {
      my $self = shift;
      sub { 
         unshift @_, $self;
         goto &refer;
      };
   };

package PApp::Callback::Function;

use Carp 'croak';

=item $cb->call([args...])

Call the callback function with the given arguments.

=cut
   
sub call($;@) {
   my $self = shift;
   my $id = $self->{func}{id};
   my $cb;
   croak "callback '$id' not registered" unless $cb = $PApp::Callback::registry{$id};
   unshift @_, @{$self->{args}};
   goto &$cb;
}

sub asString {
   my $self = shift;
   "CODE($self->{func}{id})";
}

use overload
   fallback => 1,
   '""'  => \&asString,
   '&{}' => sub {
      my $self = shift;
      sub { 
         unshift @_, $self;
         goto &call;
      };
   };

1;

=back

=head1 BUGS

 - should be able to serialize code at all costs
 - should load modules or other thingies on demand
 - the 'type' (ref $cb) of a callback is not CODE

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

