=head1 NAME

PApp::SQL - absolutely easy yet fast and powerful sql access

=head1 SYNOPSIS

 use PApp::SQL;
 # to be written

=head1 DESCRIPTION

This module provides you with easy-to-use functions to execute sql
commands (using DBI). Despite being easy to use, they are also quite
efficient and allow you to write faster programs in less lines of code.

=over 4

=cut

package PApp::SQL;

use DBI;

#use PApp::Exception; # not yet used

BEGIN {
   require Exporter;

   $VERSION = 0.06;
   @ISA = qw/Exporter/;
   @EXPORT = qw(
         sql_exec sql_fetch sql_fetchall sql_exists sql_insertid $sql_exec
   );
   @EXPORT_OK = qw(
         connect_cached
   );

   require XSLoader;
   XSLoader::load PApp::SQL, $VERSION;
}

$sql_exec;  # last result of sql_exec's execute call
$DBH;       # the default database handle

my %dbcache;

=item $dbh = connect_cached $id, $dsn, $user, $pass, $flags, $connect

(not exported by by default)

Connect to the database given by C<($dsn,$user,$pass)>, while using the
flags from C<$flags>. These are just the same arguments as given to
C<DBI->connect>.

The database handle will be cached under the unique id C<$id>. If the same
id is requested later, the cached handle will be checked (using ping), and
the connection will be re-established if necessary.

If specified, C<$connect> is a callback (e.g. a coderef) that will be
called each time a new connection is being established, with the new
C<$dbh> as first argument.

=cut

sub connect_cached {
   my ($id, $dsn, $user, $pass, $flags, $connect) = @_;
   $id = "$id\0$dsn\0$user\0$pass";
   unless ($dbcache{$id} && $dbcache{$id}->ping) {
      #warn "connecting to ($dsn|$user|$pass|$flags)\n";#d#
      # first, nuke our cache (sooory ;)
      cachesize cachesize 0;
      # then connect anew
      $dbcache{$id} = DBI->connect($dsn, $user, $pass, $flags);
      $connect->($dbcache{$id}) if $connect;
   }
   $dbcache{$id};
}

=item $sth = sql_exec [dbh,] [bind-vals...,] "sql-statement", [arguments...]

C<sql_exec> is the most important and most-used function in this module.

Runs the given sql command with the given parameters and returns the
statement handle. The command and the statement handle will be cached
(with the database handle and the sql string as key), so prepare will be
called only once for each distinct sql call (please keep in mind that the
returned statement will always be the same, so, if you call C<sql_exec>
with the same dbh and sql-statement twice (e.g. in a subroutine you
called), the statement handle for the first call mustn't be used.

The database handle (the first argument) is optional. If it is missing,
C<sql_exec> first tries to use the variable C<$DBH> in the current (=
calling) package and, if that fails, it tries to use database handle in
C<$PApp::SQL::DBH>, which you can set before calling these functions.

The actual return value from the C<$sth->execute> call is stored in the
package-global (and exported) variable C<$sql_exec>.

If any error occurs C<sql_exec> will throw an exception.

Examples:

 # easy one
 my $st = sql_exec "select name, id from table where id = ?", $id;
 while (my ($name, $id) = $st->fetchrow_array) { ... };

 # the fastest way to use dbi, using bind_columns
 my $st = sql_exec \my($name, $id),
                   "select name, id from table where id = ?",
                   $id;
 while ($st->fetch) { ...}

 # now use a different dastabase:
 sql_exec $dbh, "update file set name = ?", "oops.txt";


=item sql_fetch <see sql_exec>

Execute a sql-statement and fetch the first row of results. Depending on
the caller context the row will be returned as a list (array context), or
just the first columns. In table form:

 CONTEXT	RESULT
 void		()
 scalar		first column
 list		array

C<sql_fetch> is quite efficient in conjunction with bind variables:
#FIXME#NOT YET#

 sql_fetch \my($name, $amount),
           "select name, amount from table where id name  = ?",
           "Toytest";

But of course the normal way to call it is simply:

 my($name, $amount) = sql_fetch "select ...", args...

... and it's still fast enough unless you fetch large amounts of data.

=item sql_fetchall <see sql_exec>

Similarly to C<sql_fetch>, but all result rows will be fetched (this is
of course inefficient for large results!). The context is ignored (only
list context makes sense), but the result still depends on the number of
columns in the result:

 COLUMNS	RESULT
 0		()
 1		(row1, row2, row3...)
 many		([row1], [row2], [row3]...)

Examples (all of which are inefficient):

 for (sql_fetchall "select id from table") { ... }

 my @names = sql_fetchall "select name from user";

 for (sql_fetchall "select name, age, place from user") {
    my ($name, $age, $place) = @$_;
 }

=item sql_exists "<table> where ...", args...

Check wether the result of the sql-statement "select xxx from
$first_argument" would be empty or not (that is, imagine the string
"select from" were prepended to your statement (it isn't)). Should work
with every database but can be quite slow, except on mysql, where this
should be quite fast.

Examples:

 print "user 7 exists!\n"
    if sql_exists "user where id = ?", 7;
 
 die "duplicate key"
    if sql_exists "user where name = ? and pass = ?", "stefan", "geheim";

=cut

# uncodumented, since unportable. yet it is exportet (aaargh!)
sub sql_insertid {
   $DBH->{mysql_insertid};
}

=item [old-size] = cachesize [new-size]

Returns (and possibly changes) the LRU cache size used by C<sql_exec>. The
default is somewhere around 50 (= the 50 last recently used statements
will be cached). It shouldn't be too large, since a simple linear listed
is used for the cache at the moment (which, for small (<100) cache sizes
is actually quite fast).

The function always returns the cache size in effect I<before> the call,
so, to nuke the cache (for example, when a database connection has died
or you want to garbage collect old database/statement handles), this
construct can be used:

 PApp::SQL::cachesize PApp::SQL::cachesize 0;

=cut

=begin comment

# this is of historical interest at best ;) well, actually the
# calls to fancydie are quite nice...

my %_sql_st;

sub sql_exec($;@) {
   my $statement = shift;
   my $st = $_sql_st{$statement};
   unless($st) {
      $st = $db->prepare($statement) or fancydie "unable to prepare statement", $statement;
      $_sql_st{$statement} = $st;
   }
   if (ref $_[0]) {
      my $bind = shift;
      $sql_exec = $st->execute(@_) or fancydie $db->errstr, "Unable to execute statement `$statement` with ".join(":",@_);
      $st->bind_columns(@$bind) or fancydie $db->errstr, "Unable to bind_columns to statement `$statement` with ".join(":",@_);
   } else {
      $sql_exec = $st->execute(@_) or fancydie $db->errstr, "Unable to execute statement `$statement` with ".join(":",@_);
   }
   $st;
}

sub sql_fetch {
   my $r = &sql_exec->fetchrow_arrayref;
   $r ? wantarray ? @{$r}
                  : $r->[0]
      : ();
}

sub sql_fetchall {
   my $r = &sql_exec->fetchall_arrayref;
   ref $r && @$r ? @{$r->[0]}==1 ? map @$_,@$r
                                 : @$r
		 : ();
}

sub sql_exists($;@) {
   my $select = shift;
   my @args = @_;
   $select = "select count(*) > 0 from $select limit 1";
   @_ = ($select, @_);
   goto &sql_fetch;
}

=end comment

=cut

1;

=back

=head1 BUGS

As of this writing, sql_fetch and sql_fetchall are not very well tested
(they were just re-written in C).

sql_exists could be faster (it is written very ugly to not change the
current package).

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

