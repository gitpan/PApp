=head1 NAME

PApp::Env - communicate between processes and the outside.

=head1 SYNOPSIS

 use PApp::Env;

=head1 DESCRIPTION

This module can be used to get and set some kind of "environment"
variables shared between all papp applications. When inside a PApp
environment (e.g. inside a papp program) this module uses PApp's state
database handle. Outside the module it tries to open a connection to the
database itself, so it can be used e.g. from shell script to communicate
data asynchronously to the module.

If you pass in a reference, the Storable module (L<Storable>) will be used
to serialize and deserialize it.

Environment variable names (often referred as key in this document) are
treated case-insensitive if the database allows it. The contents will be
treated as opaque binary objects (again, if the database supports it).

The only database supported by this module is MySQL, so the above is
currently true in all cases.

=over 4

=cut

package PApp::Env;

use Storable;
use PApp::SQL;

require Exporter;

@ISA = qw(Exporter);
$VERSION = 0.08;
@EXPORT = qw(setenv getenv unsetenv modifyenv lockenv listenv);

=item PApp::Env->configure name => value, ...

Used to configure the papp module. Only the following keys are currently
understood:

  statedb	the dsn of the papp database
  statedb_user	the username used to open the dbi connection
  statedb_pass	the password used to open the connection

Defaults for these will be fetched from the PApp::Config module (L<PApp::Config>).

=cut

sub configure {
   my %attr = @_;
   exists $attr{statedb}      and $statedb = $attr{statedb};
   exists $attr{statedb_user} and $statedb = $attr{statedb_user};
   exists $attr{statedb_pass} and $statedb = $attr{statedb_pass};

   $configured = 1;
}

our $statedb;
our $statedb_user;
our $statedb_pass;
our $configured;

sub dbconnect {
   if (defined $PApp::statedbh) {
      $DBH = $PApp::statedbh;
   } else {
      unless ($configured) {
         require PApp::Config;
         $statedb      ||= $PApp::Config{STATEDB};
         $statedb_user ||= $PApp::Config{STATEDB_USER};
         $statedb_pass ||= $PApp::Config{STATEDB_PASS};
         $configured = 1;
      }

      $DBH = PApp::SQL::connect_cached(__PACKAGE__ . __FILE__, $statedb, $statedb_user, $statedb_pass);
   }
}

=item setenv key => value

Sets a single environment variable to the specified value. (mysql-specific ;)

=cut

sub setenv($$) {
   dbconnect unless $DBH;
   my ($key, $val) = @_;

   $val = "\x00".Storable::nfreeze($val)
      if ref $val || !defined $val || substr($val, 0, 1) eq "\x00";

   sql_exec "replace into env (name, value) values (?, ?)", $key, $val;
}

=item unsetenv key

Unsets (removes) the specified environment variable.

=cut

sub unsetenv($) {
   dbconnect unless $DBH;
   my $key = shift;
   sql_exec "delete from env where name = ?", $key;
}

=item getenv key

Return the value of the specified environment value

=cut

sub getenv($) {
   dbconnect unless $DBH;
   my $key = shift;
   my $st = sql_exec \my($val), "select value from env where name = ?", $key;
   if ($st->fetch) {
      substr ($val, 0, 1) eq "\x00" ? Storable::thaw(substr $val, 1) : $val;
   } else {
      ();
   }
}

=item lockenv BLOCK

Locks the environment table against modifications (this is, again,
only implemented for mysql so far), while executing the specified
block. Returns the return value of BLOCK (which is called in scalar
context).

Calls to lockenv can be nested.

=cut

our $locklevel;

sub lockenv(&) {
   dbconnect unless $DBH;
   sql_exec "lock tables env write" unless $locklevel;
   my $res = eval { local $locklevel=$locklevel+1; $_[0]->() };
   my $err = $@;
   sql_exec "unlock tables" unless $locklevel;
   die $@ if $@;
   $res;
}

=item modifyenv BLOCK key

Modifies the specified environment variable atomically by calling code-ref
with the value as first argument. The code-reference must modify the
argument in-place, e.g.:

   modifyenv { $_[0]++ } "myapp_counter";

The modification will be done atomically. C<modifyenv> returns whatever
the BLOCK returned.

=cut

sub modifyenv(&$) {
   my ($code, $key) = @_;
   my $res;
   lockenv {
      my $val = getenv $key;
      $res = $code->($val);
      setenv $key, $val;
   };
   $res;
}

=item @list = listenv

Returns a list of all environment variables (names).

=cut

sub listenv {
   dbconnect unless $DBH;
   sql_fetchall "select name from env";
}

1;

=back

=head1 BUGS

 - should also support a tied hash interface.

 - setenv requires mysql (actually a replace command), but it's so much
   easier & faster that way.

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

