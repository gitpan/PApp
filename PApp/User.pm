=head1 NAME

PApp::User - manage user and access rights

=head1 SYNOPSIS

 use PApp::User;

=head1 DESCRIPTION

This module helps administrate users and groups (groups are more commonly
called "access rights" within PApp). Wherever a so-called "group" or
"access right" is required you can either use a string (group name) or a
number (the numerical group id).

Both usernames and group names must be valid XML-Names (this might or
might not be enforced).

The API in this module is rather borken. A nicer, more sane interface will
be created at some point.

=cut

package PApp::User;

use PApp::SQL;
use PApp::Exception qw(fancydie);
use PApp::Callback ();
use PApp::Config qw($DBH);
use PApp qw(*state $userid);

use base Exporter;

$VERSION = 0.12;
@EXPORT = qw( 
   authen_p access_p admin_p known_user_p update_username choose_username
   update_password update_comment username user_login user_logout
   SURL_USER_LOGOUT user_delete grant_access revoke_access verify_login

   grpid grpname
);

sub grpid($);

=head2 FUNCTIONS

=over 4

=item authen_p

Return true when the user has logged on using this module

=cut

sub authen_p() {
   use bytes;
   vec $state{papp_access}, 0, 1;
}

=item access_p

Return true when the user has the specified access right (and is logged
in!).

=cut

sub access_p($) {
   use bytes;
   vec $state{papp_access}, grpid $_[0], 1;
}

=item admin_p

Return true when user has the "admin" access right.

=cut

sub admin_p() {
   use bytes;
   vec $state{papp_access}, grpid "admin", 1;
}

=item userid $username

Return the userid associated with the given user.

=cut

sub userid($) {
   sql_fetch "select id from user where name like ?", $_[0];
}

=item known_user_p [access]

Check wether the current user is already known in the access
database. Returns his username (login) if yes, and nothing otherwise.

If the optional argument C<access> is given, it additionally checks wether
the user has the given access right (even if not logged in).

=cut

sub known_user_p(;$) {
   my $user = sql_fetch "select user from user where id = ?",
                        $userid;
   if (@_) {
      (sql_exists "usergrp where userid = ? and grpid = ?",
                  $userid, grpid shift) ? $user : ();
   } else {
      $user;
   }
}

sub _nuke_access() {
   delete $state{papp_access};
}

# get access info from database
sub _fetch_access() {
   _nuke_access;

   use bytes;
   my $st = sql_exec \my($gid),
                     "select grpid from usergrp where userid = ?",
                     $userid;
   vec ($state{papp_access}, $gid, 1) = 1 while $st->fetch;
   vec ($state{papp_access}, 0, 1) = 1; # validity
}

=item update_username [$userid, ]$user

Change the login-name of the current user (or the user with id $userid)
to C<$user> and return the userid. If another user of that name already
exists, do nothing and return C<undef>. (See C<choose_username>).

=cut

sub update_username($;$) {
   my $uid = @_ > 1 ? shift : $userid;
   my $user = $_[0];
   $DBH->do("lock tables user write");
   if (sql_fetch "select count(*) from user where user = ? and id != ?", $user, $uid) {
      undef $uid;
   } else {
      sql_exec "update user set user = ? where id = ?", $user, $uid;
   }
   $DBH->do("unlock tables");
   $uid;
}

=item choose_username $stem

Guess a more-or-less viable but very probable unique username from the
stem given. To create a new username that is unique, use something like
this pseudo-code:

   while not update_username $username; do
      $username = choose_username $username
   done

=cut

sub choose_username($) {
   my $stem = $_[0];
   my $id;
   my $st = $DBH->prepare("select count(*) from user where user = ?");
   for(;;) {
      my $user = $stem.$id;
      $st->execute($user);
      return $user unless $st->fetchrow_arrayref->[0];
      $id += 1 + int rand 20;
   }
}

=item update_password $pass

Set the (non-crypted) password of the current user to C<$pass>. If
C<$pass> is C<undef>, the password will be deleted and the user cannot
log-in using C<verify_login> anymore. This is not the same as an empty
password, which is just that: a valid password with length zero.

=cut

sub update_password($) {
   my ($pass) = @_;
   $pass = defined $pass
              ? crypt $pass, join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64]
              : "";
   my $st = $DBH->prepare("update user set pass = ? where id = ?");
   $st->execute($pass, $userid);
}

=item update_comment $comment

Change the comment field for the given user by setting it to C<$comment>.

=cut

sub update_comment($) {
   my ($comment) = @_;
   my $st = $DBH->prepare("update user set comment = ? where id = ?");
   $st->execute($comment, $userid);
}

=item username [$userid]

Return the username of the user with id C<$userid> or of the current user,
if no arguments are given.

=cut

sub username(;$) {
   my $uid = shift || $userid;
   my $st = $DBH->prepare("select user from user where id = ?");
   $st->execute($uid);
   ($st->fetchrow_array)[0];
}

=item user_login $userid

Log out the current user, switch to the userid C<$userid> and
UNCONDITIONALLY FETCH ACCESS RIGHTS FROM THE USER DB. For a safer
interface using password, see C<verify_login>.

If the C<$userid> is zero creates a new user without any access rights but
keeps the state otherwise unchanged. You might want to call C<save_prefs>
to save the user preferences (for the current application only, the other
preferences currently are discarded).

=cut

sub user_login($) {
   user_logout;
   PApp::switch_userid $_[0];
   _fetch_access;
}

=item user_logout

Log the current user out (remove any access rights fromt he current
session).

=cut

sub user_logout() {
   _nuke_access;
}

my $surl_logout_cb = PApp::Callback::create_callback {
   &user_logout;
   warn "huphup\n";#d#
} name => "papp_logout";

=item SURL_USER_LOGOUT

This surl-cookie (see C<PApp::surl> logs the user out (see C<user_logout>)
when the link is followed.

=cut

sub SURL_USER_LOGOUT (){ ( PApp::SURL_EXEC, $surl_logout_cb ) }

=item user_delete $userid

Deletes the givne userid from the system, i.e. the user with the given ID
can no longer log-in or do useful things. Other sessions using this userid
will get errors, so don't use this function lightly.

=cut

sub user_delete(;$) {
   my $uid = shift || $userid;
   user_login 0 if $userid == $uid;
   sql_exec "delete from usergrp where userid = ?", $uid;
   sql_exec "delete from user where id = ?", $uid;
}

=item grant_access accessright

Grant the specified access right to the logged-in user.

=cut

sub grant_access($) {
   my $right = shift;
   if (authen_p) {
      sql_exec "replace into usergrp values (?, ?)", $userid, grpid $right;
      _fetch_access;
   } else {
      fancydie "Internal error", "grant_access was called but no user was logged in";
   }
}

=item revoke_access accessright

Revoke the specified access right to the logged-in user.

=cut

sub revoke_access($) {
   my $right = shift;
   if (authen_p) {
      sql_exec "delete from usergrp where userid = ? and grpid = ?", $userid, grpid $right;
      _fetch_access;
   } else {
      fancydie "Internal error", "revoke_access was called but no user was logged in";
   }
}

=item verify_login $user, $pass

Try to login as user $user, with pass $pass. If the password verifies
correctly, switch the userid (if necessary), add any access rights and
return true. Otherwise, return false and do nothing else.

Unlike the unix password system, empty password fields (i.e. set to undef)
never log-in successfully using this function.

=cut

sub verify_login($$) {
   my ($user, $pass) = @_;
   my $st = sql_exec \my($userid, $xpass),
                     "select id, pass from user where user = ?",
                     $user;
   if (!$st->fetch || $userid == 0 || $xpass ne crypt $pass, substr($xpass,0,2)) {
      sleep 3;
      return 0;
   } else {
      user_login $userid;
      return 1;
   }
}

=item grpid grpname-or-grpid

Return the numerical group id of the given group.

=cut

sub grpid($) {
   $gid_cache{$_[0]} ||= 
       ($_[0] > 0
          ? $_[0]
          : sql_fetch "select id from grp where name = ?",
                       "$_[0]") || -1;
}

=item grpname $gid

Return the group name associated with the given id.

=cut

sub grpname($) {
   sql_fetch "select name from grp where id = ?", $_[0];
}

=item newgrp $grpname, $comment

Create a new group with the given name.

=cut

sub newgrp($;$) {
   my ($grp, $comment) = @_;
   sql_exec "insert into grp (name, longdesc) values (?, ?)",
            "$grp", "$comment";
}

=item rmgrp $group

Delete the group with the given name.

=cut

sub rmgrp($) {
   sql_exec "delete from usergrp where grpid = ?", grpid $_[0];
   sql_exec "delete from grp where id = ?", grpid $_[0];
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

