=head1 NAME

PApp::Session - manage session-specific data.

=head1 SYNOPSIS

 use PApp::Session;
 # see also PApp::Prefs and PApp::Env

=head1 DESCRIPTION

=cut

package PApp::Session;

use Compress::LZF qw(:freeze);

use PApp::SQL;
use PApp::Exception qw(fancydie);
use PApp::Callback ();
use PApp::Config qw(DBH $DBH); DBH;

use base Exporter;

$VERSION = 0.22;
@EXPORT = qw( 
   locksession
);

use Convert::Scalar ();

=head2 FUNCTIONS

=over 4

=item locksession { BLOCK }

Execute the given block while the session table is locked against changes
from other processes. Needless to say, the block should execute as fast
as possible. Returns the return value of BLOCK (which is called in scalar
context).

=cut

sub locksession(&) {
   sql_fetch $DBH, "select get_lock('PAPP_SESSION_LOCK_SESSION', 60)"
      or fancydie "PApp::Session::locksession: unable to aquire database lock";
   my $res = eval { $_[0]->() };
   {
      local $@;
      sql_exec $DBH, "select release_lock('PAPP_SESSION_LOCK_SESSION')";
   }
   die if $@;
   $res;
}

=back

=head2 METHODS

=over 4

=item $session = new PApp::Session [$pathref]

Creates a new PApp::Session object for the given session id and
application path. A reference to the path variable must be apssed in, so
that changes in the path can be tracked by the module.

=cut

sub new {
   bless { path => $_[1] }, $_[0];
}

=item $session->get($key)

Return the named session variable (or undef, when the variable does not
exist).

=item $session->set($key, $value)

Set the named session variable. If C<$value> is C<undef>, then the
variable will be deleted. You can pass in (serializable) references.

=item $ref = $session->ref($key)

Return a reference to the session value (i.e. a L<PApp::DataRef>
object). Updates to the referee will be seen by all processes.

=cut

sub get($$) {
   sthaw sql_ufetch $DBH, "select value from session where sid = ? and name = ?",
                    $PApp::sessionid, Convert::Scalar::utf8_upgrade "${$_[0]{path}}/$_[1]";
}

sub set($$;$) {
   if (defined $_[2]) {
      sql_exec $DBH, "replace into session (sid, name, value) values (?, ?, ?)",
               $PApp::sessionid, Convert::Scalar::utf8_upgrade "${$_[0]{path}}/$_[1]", 
               sfreeze_cr $_[2];
   } else {
      sql_exec $DBH, "delete from session where sid = ? and name = ?",
               $PApp::sessionid, Convert::Scalar::utf8_upgrade "${$_[0]{path}}/$_[1]";
   }
}

sub ref($$) {
   require PApp::DataRef;

   \(new PApp::DataRef 'DB_row',
         database => $PApp::Config::Database,
         table    => "session", 
         key      => [qw(sid name)],
         id       => [$PApp::sessionid, "${$_[0]{path}}/$_[1]"],
         utf8     => 1,
   )->{
      ["value", PApp::DataRef::DB_row::filter_sfreeze_cr]
   };
}

=back

=head1 SEE ALSO

L<PApp::Prefs>, L<PApp::Env>, L<PApp>, L<PApp::User>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

