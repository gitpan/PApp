=head1 NAME

PApp::Prefs - manage user-specific and transaction data.

=head1 SYNOPSIS

 use PApp::Prefs;

=head1 DESCRIPTION

=cut

package PApp::Prefs;

use Compress::LZF qw(:freeze);

use PApp::SQL;
use PApp::Exception qw(fancydie);
use PApp::Callback ();
use PApp::Config qw($DBH);

use base Exporter;

$VERSION = 0.142;
@EXPORT = qw( 
   lockprefs
);

use Convert::Scalar ();

=head2 FUNCTIONS

=over 4

=item lockprefs { BLOCK }

Execute the given block while the user preferences table is locked against
changes from other processes. Needless to say, the block should execute as
fast as possible. Returns the return value of BLOCK (which is called in
scalar context).

=cut

sub lockprefs(&) {
   sql_fetch $DBH, "select get_lock('PAPP_PREFS_LOCK_PREFS', 60)"
      or fancydie "PApp::Prefs::lockprefs: unable to aquire database lock";
   my $res = eval {
      local $SIG{__DIE__};
      $_[0]->();
   };
   {
      local $@;
      sql_exec $DBH, "select release_lock('PAPP_PREFS_LOCK_PREFS')";
   }
   die if $@;
   $res;
}

=back

=head2 METHODS

=over 4

=item $prefs = new PApp::Prefs [$path]

Creates a new PApp::Prefs object for the given application path. Changes
in the C<$path> variable are being tracked by the module, as it takes a
reference to the variable.

=cut

sub new {
   bless { path => \$_[1] }, $_[0];
}

=item $prefs->get($key)

Return the named user-preference variable (or undef, when the variable
does not exist).

User preferences can be abused for other means, like timeout-based session
authenticitation. This works, because user preferences, unlike state
variables, change their values simultaneously in all sessions.

=item $prefs->set($key, $value)

Set the named preference variable. If C<$value> is C<undef>, then the
variable will be deleted. You can pass in (serializable) references.

=item $ref = $prefs->ref($key)

Return a reference to the preferences value (i.e. a L<PApp::DataRef>
object). Updates to the referee will be seen by all processes.

=item $prefs->user_get($uid, $key)

=item $prefs->user_set($uid, $key, $value)

=item $prefs->user_ref($uid, $key)

These functions work like their counterparts without the C<user_>-prefix, but allow you
to specify the userid you want to query.

=cut

sub user_get($$$) {
   sthaw sql_ufetch $DBH, "select value from prefs where uid = ? and path = ? and name = ?",
                    $_[1], ${$_[0]{path}}, $_[2];
}

sub user_set($$$;$) {
   if (defined $_[2]) {
      $PApp::st_replacepref->execute($_[1], ${$_[0]{path}}, Convert::Scalar::utf8_upgrade $_[2],
                                sfreeze_cr $_[3]);
   } else {
      $PApp::st_deletepref->execute($_[1], ${$_[0]{path}}, Convert::Scalar::utf8_upgrade $_[2]);
   }
}

sub user_ref($$$) {
   require PApp::DataRef;

   \(new PApp::DataRef 'DB_row',
         database => $PApp::Config::Database,
         table    => "prefs", 
         key      => [qw(uid path name)],
         id       => [$_[1], ${$_[0]{path}}, $_[2]],
         utf8     => 1,
   )->{
      ["value", PApp::DataRef::DB_row::filter_sfreeze_cr]
   };
}

sub get($$) {
   $_[0]->user_get($PApp::userid, $_[1]);
}

sub set($$;$) {
   $_[0]->user_set($PApp::userid, $_[1], $_[2]);
}

sub ref($$) {
   $_[0]->user_ref($PApp::userid, $_[1]);
}

=item @uids = $prefs->find_value($key, $value)

Return all user ids for which the named key has the given value.

Useful for login-type functions where you look for all users with a
specific value for the "username" key or similar.

=cut

sub find_value($$$) {
   sql_ufetchall $DBH, "select uid from prefs where path = ? and name = ? and value = ?",
                 ${$_[0]{path}}, $_[1], $_[2];
}

=back

=head1 SEE ALSO

L<PApp>, L<PApp::User>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

