use Config;

$PAPPRC = "$ENV{HOME}/.papp_config";

$|=1;

eval {
   require "PApp/Config.pm";
   require "./config";
   $CFG{$k} = $v while ($k, $v) = each %PApp::Config::Config;
};
if ($@) {
   eval {
      require PApp::Config;
      $CFG{$k} = $v while my ($k, $v) = each %PApp::Config::Config;
   };
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
get_value 0, "STATEDB", "papp database", "DBI:mysql:papp";
get_value 0, "STATEDB_USER", "papp database user", "";

$cfg2 = "$CFG{LIBDIR}/config";

print <<EOF;

The following values will be stored in the file $cfg2
and are security-sensitive. Secure this file with appropriate permissions
after running "make install".

If you do not want to specify them here just leave them empty (you can
override them for each program/server).

EOF

get_value 1, "STATEDB_PASS", "papp database password", "";
srand;
get_value 1, "CIPHERKEY", "the serverwide cipherkey", join "", map sprintf("%02x", rand 256), 0..16;

$cfg2 = "config";

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

$VERSION = 0.04;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw();

%papp; # loaded applications
%pimp; # loaded imports

=item @paths = search_path [path...]

Return the standard search path and optionally add additional paths.

=cut

%Config = (
EOF

print "Writing $cfg2\n";
open CFG2, ">", $cfg2 or die "$cfg2: $!\n";
print CFG2 "package PApp::Config;\n\n";

while (my ($k, $v) = each %CFG) {
   if ($secure{$k}) {
      printf CFG2 "\$Config%-20s = %s;\n", "{\"\Q$k\E\"}", "\"\Q$v\E\"";
   } else {
      printf PM "%-20s => %s,\n", "\"\Q$k\E\"", "\"\Q$v\E\"";
   }
}

print CFG2 "\n1;\n";

print PM <<'EOF';
);

our $secureconfig = do "$Config{LIBDIR}/config";

my @incpath;

sub search_path {
   push @incpath, @_;
   @incpath;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

Marc Lehmann <pcg@goof.com>

=cut
EOF

1;

