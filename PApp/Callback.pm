=head1 NAME

PApp::Callback - a workaround for the problem of nonserializable code.

=head1 SYNOPSIS

 use PApp::Callback;

 my $function = register_callback BLOCK [key => value...];
 my $cb = $function->refer([args...]);

 &$cb;

 my $cb = create_callback BLOCK [key => value...];

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

use base 'Exporter';

$VERSION = 0.12;
@EXPORT = qw(register_callback create_callback);

=item register_callback functiondef, key => value...

Registers a function (preferably at program start) and returns a callback
object that can be used to create callable but serializable objects.

If C<functiondef> is a string it will be interpreted as a function name in
the callers package (unless it conatins '::'). Otherwise you should use a
"name => <funname>" argument to uniquely identify the function. If it is
omitted the filename and linenumber will be used, but that is fragile.

Examples:

 my $func = register_callback {
               print "arg1=$_[0] (should be 5), arg2=$_[1] (should be 7)\n";
            } name => "toytest_myfunc1";

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

   $attr{__do_refer} ? $self->refer : $self;
}

=item create_callback <same arguments as register_callback>

Just like C<register_callback>, but additionally calls C<refer> on the
result, returning the function reference directly.

=cut

sub create_callback(&;@) {
   push @_, __do_refer => 1;
   goto &register_callback;
}

=item $cb = $func->refer([args...])

Create a callable object (a code reference). The callback C<$cb> can
either be executed by calling the C<call> method or by treating it as a
code reference, e.g.:

 $cb->call(4,5,6);
 $cb->(4,5,6);
 &$cb; # this does not work with Storable-0.611 and below

It will behave as if the original registered callback function would be
called with the arguments given to C<register_callback> first and then the
arguments given to the C<call>-method.

C<refer> is implemented in a fast way and the returned objects are
optimised to be as small as possible.

=cut

sub refer($;@) {
   my $self = shift;
   my @func = $self->{id};
   push @func, [@_] if @_;
   bless \@func, PApp::Callback::Function;
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

# a Function is a [$id, \@args]

=item $cb->call([args...])

Call the callback function with the given arguments.

=cut
   
sub call($;@) {
   my $self = shift;
   my ($id, $args) = @$self;
   my $cb = $PApp::Callback::registry{$id};
   unless ($cb) {
      #d#
      # too bad, no callback -> try to load applications
      # until callback is found or everything is in memory
      for (values %PApp::papp) {
         $_->load_code;
         last if $cb = $PApp::Callback::registry{$id};
      }
   }
   $cb or croak "callback '$id' not registered";
   unshift @_, @$args;
   goto &$cb;
}

sub asString {
   my $self = shift;
   "CODE($self->[0])";
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

