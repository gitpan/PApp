use Config;

$PAPPRC = "$ENV{HOME}/.papp_config";

if (-t STDIN) {
   # flush input
   use POSIX ();
   POSIX::tcflush 0, POSIX::TCIFLUSH;
}

$|=1;

eval {
   require "./PApp/Config.pm";
   require "./config.pl";
   %CFG = %PApp::Config;
};
if ($@) {
   print "[notice] unable to read new configuration\n";
   eval {
      require PApp::Config;
      %CFG = %PApp::Config;
      1;
   } or
      print "[notice] unable to read already-installed configuration\n";
}

if (-e $PAPPRC) {
   print "using values from $PAPPRC\n";
   do $PAPPRC;
}

sub get_value($$$$) {
   my ($sec, $var, $desc, $default) = @_;
   $secure{$var} = $sec;
   $CFG{$var} = $default unless defined $CFG{$var};
   #unless (defined $CFG{$var}) {
      print "$desc [$CFG{$var}]? ";
      chomp (my $res = <STDIN>);
      $res =~ s/^\"(.*)\"$/$1/s;
      $CFG{$var} = $res if $res =~ /\S/;
   #}
}

print <<EOF;

Welcome to the PApp configuration ;)

Please read the INSTALL file for instructions on what the various
questions mean.

EOF

get_value 0, "LIBDIR",  "papp library directory", "$Config{installprefixexp}/lib/papp";
get_value 0, "I18NDIR", "directory for i18n tables", "$CFG{LIBDIR}/i18n";

print <<EOF;

Please enter a system ID. A system ID is a number that uniquely identifies
your PApp installation (one papp database - one papp sysid). Please
don't make up system id's, either ask for a system ID by writing to
sysid\@nethype.de, stating something that we can use to uniquely identify
you (we keep a database of sysids, anonymized if you want), or use an
official(!) IPv4 address assigned to you.

See the FAQ entry "Why do I need a sysid?"

EOF

get_value 0, "SYSID", "unique system id", "0";

use Socket;
$CFG{SYSID} = unpack "N", Socket::inet_aton $CFG{SYSID};

print <<EOF;

PApp will usually run as a specific user/group (e.g. www/www). All files
installed will be chown'ed to that uid/gid, including the file that
contains "secret" information.

EOF

do {
   if (defined getpwuid $CFG{PAPP_UID}) {
      $CFG{PAPP_UID} = getpwuid ($CFG{PAPP_UID});
   } 
   get_value 0, "PAPP_UID", "papp user id", "0";
} until (($CFG{PAPP_UID} ne ((getpwnam $CFG{PAPP_UID})[2])
          && defined ((getpwnam $CFG{PAPP_UID})[2]))
         || ($CFG{PAPP_UID} =~ /^\d+$/));

do {
   if (defined getgrgid $CFG{PAPP_GID}) {
      $CFG{PAPP_GID} = getgrgid ($CFG{PAPP_GID});
   }
   get_value 0, "PAPP_GID", "papp group id", "0";
} until (($CFG{PAPP_GID} ne ((getgrnam $CFG{PAPP_GID})[2])
          && defined ((getgrnam $CFG{PAPP_GID})[2]))
         || ($CFG{PAPP_GID} =~ /^\d+$/));

$CFG{PAPP_UID} &&= (getpwnam $CFG{PAPP_UID})[2] || $CFG{PAPP_UID};
$CFG{PAPP_GID} &&= (getgrnam $CFG{PAPP_GID})[2] || $CFG{PAPP_GID};

print <<EOF;

PApp requires a database for it to function properly. The default should
probably be a MySQL database (which will be created if necessary),
for other databases you must modify the CREATE statements in the
"papp-install" script (or create the database manually).

EOF

get_value 0, "STATEDB", "papp database", "DBI:mysql:papp";

get_value 0, "STATEDB_USER", "papp database user", "";

$cfg2 = "$CFG{LIBDIR}/config.pl";

print <<EOF;

The following values will be stored in the file $cfg2 and are
security-sensitive. Secure this file with appropriate permissions after
running "make install".

If you do not want to specify them here just leave them empty (you can
override them for each program/server).

EOF

get_value 1, "STATEDB_PASS", "papp database password", "";
srand;
get_value 1, "CIPHERKEY", "the serverwide cipherkey", join "", map sprintf("%02x", rand 256), 0..31;

$cfg2 = "config.pl";

print <<EOF;

Congratulations! Interactive configuration is complete!

EOF

print "Writing PApp/Config.pm\n";
open PM, ">PApp/Config.pm" or die "PApp/Config.pm: $!\n";
print PM <<'EOF';
package PApp::Config;

=head1 NAME

PApp::Config - hold common configuration settings

=over 4

=cut

use PApp::SQL;

$VERSION = 0.22;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw($DBH DBH $Database);

our %papp; # loaded applications
our %pimp; # loaded imports
our $DBH;

=item @paths = search_path [path...]

Return the standard search path and optionally add additional paths. (The
returned path entries might or might not include the arguments).

=back

=head2 DEFINED KEYS IN THE C<%PApp::Config> HASH

The following configuration items are available in the C<%PApp::Config>
hash. Keys marked with a star (*) are access-restricted and can only be
accessed from processes having read-access to the config file in libdir.

=over 4

=item SECURE

A boolean indicating wether secure configuration values (marked with an
"*") are available (or not).

=item LIBDIR

The standard papp library directory.

=item I18NDIR

The directory where translation files are being storerd (usually
"LIBDIR/i18n").

=item STATEDB

The DSN specification for papp's statedb (also used by poedit and
acedit). Usually something like 'DBI:mysql:papp'.

=item STATEDB_USER, STATEDB_PASS*

The username and password to access the state database.

=item CIPHERKEY*

The cipherkey to use to encrypt cookies.

=back

=cut

%PApp::Config = (
EOF

print "Writing $cfg2\n";
open CFG2, ">", $cfg2 or die "$cfg2: $!\n";
chmod 0600, $cfg2;

while (my ($k, $v) = each %CFG) {
   if ($secure{$k}) {
      printf CFG2 "\$PApp::Config%-20s = %s;\n", "{\"\Q$k\E\"}", "\"\Q$v\E\"";
   } elsif ($k ne "SECURE") {
      printf PM "%-20s => %s,\n", "\"\Q$k\E\"", "\"\Q$v\E\"";
   }
}

print CFG2 "\n1;\n";

print PM <<'EOF';
);

$PApp::Config{SECURE} = do ($PApp::Config::CONFIG_PL ? $PApp::Config::CONFIG_PL : "$PApp::Config{LIBDIR}/config.pl");

our @incpath = $PApp::Config{LIBDIR};

sub search_path {
   push @incpath, @_;
   @incpath;
}

$PApp::statedb      = $PApp::Config{STATEDB};
$PApp::statedb_user = $PApp::Config{STATEDB_USER};
$PApp::statedb_pass = $PApp::Config{STATEDB_PASS};

# "inlined" into DBH
$Database = new PApp::SQL::Database "papp_1", $PApp::statedb, $PApp::statedb_user, $PApp::statedb_pass;

sub _prepare_DBH {
   my $dbh = shift;

   $PApp::st_fetchstate  = $dbh->prepare("select count, state, userid, previd, sessid from event_count left join state on (id = ?)");
   $PApp::st_newstateids = $dbh->prepare("update state_seq set seq = last_insert_id(seq) + ?");
   $PApp::st_insertstate = $dbh->prepare("replace into state (id, state, userid, previd, sessid, alternative) values (?,?,?,?,?,?)");
   $PApp::st_eventcount  = $dbh->prepare("select count from event_count");
   $PApp::st_reload_p    = $dbh->prepare("select count(*) from state where previd = ? and alternative = ?");
   $PApp::st_newuserid   = $dbh->prepare("update user_seq set seq = last_insert_id(seq) + 1");
   $PApp::st_replacepref = $dbh->prepare("replace into prefs (uid, path, name, value) values (?,?,?,?)");
   $PApp::st_deletepref  = $dbh->prepare("delete from prefs where uid = ? and path = ? and name = ?");
}

sub DBH() {
   $DBH = PApp::SQL::connect_cached("papp_1", $PApp::statedb, $PApp::statedb_user, $PApp::statedb_pass, {
      AutoCommit => 1,
      RaiseError => 1,
      PrintError => 0,
   }, \&_prepare_DBH) or die "error connecting to papp database: $DBI::errstr";
}

DBH;

1;

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

Marc Lehmann <pcg@goof.com>

=cut
EOF

1;

