package PApp::I18n;

=head1 NAME

PApp::I18n - internationalization support for PApp

=over 4

=cut

$VERSION = 0.03;

# GDBM_File is faster then DB_File, and creates smaller files
# SDBM_File is (much) faster&smaller than GDBM_File, but limits the size of key/value pairs too much
# this is not easily configurable

use GDBM_File;

use File::Glob qw(:glob);

use PApp::Exception;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(
      open_translator
);
@EXPORT_OK = qw(
      scan_file scan_init scan_end scan_field export_po export_dbm
);

=item open_translator $path

open an existing translation directory

=cut

sub open_translator {
   new PApp::I18n path => $_[0];
}

sub new {
   my $class = shift;
   my $self = { @_ };
   bless $self, $class;
}

#=item expand_lang langid, langid... [internal utility function]
#
#Try to identify the closest available language. #fixme#
#
#=cut

sub expand_lang {
   my $langs = shift;
   my $lang;
   my %lang;
   @lang{@_} = @_;

   lang_loop:
   for (split /,/, $langs) {
      $lang = $_; $lang =~ s/^\s+//; $lang =~ s/\s+$//; $lang =~ y/-/_/;
      next unless $lang;
      last if exists $lang{$lang};
      $lang =~ s/_.*$//;
      last if exists $lang{$lang};
      for (keys %lang) {
         if (/^${lang}_/) {
            $lang = $_;
            last lang_loop;
         }
      }
   }
   $lang || "default";
}

=item ($lang, $table) = $translator->get_language($languages)

In scalar context, return a translator table for the language that best
matches the C<$languages> (always succeeds). In list context, return both
the selected language and the translation table.

=cut

sub get_language {
   my $self = shift;
   my $langs = shift;
   # first, map the "langs" into a real language code
   my $lang = $self->{lang}{$langs};
   unless ($lang) {
      my @langs = map { s/^.*\///; s/\.dpo$//; $_ } File::Glob::glob "$self->{path}/*.dpo", GLOB_NOSORT;
      $self->{lang}{$langs} = $lang = expand_lang $langs, @langs;
   }
   # then map the lang into the corresponding GDBM_File
   my $db = $self->{db}{$lang};
   unless ($db) {
      $self->{db}{$lang} = $db = tie %{$self->{tie} = {}}, 'GDBM_File', "$self->{path}/$lang.dpo", &GDBM_READER, 0000;
      $db or fancydie "unable to find default translation table '$lang'", "in directory '$self->{path}'";
   }
   ($lang, $db);
}

=item $translation = $table->fetch($message)

Find the translation for $message.

=cut

sub PApp::I18n::Table::fetch {
   #warn "called from @{[caller]}, db $_[0] for '$_[1]'\n";#d#
   my $msg = GDBM_File::FETCH($_[0], $_[1]);
   defined $msg ? $msg : $_[1];
}

#############################################################################

use PApp::SQL;
use String::Similarity 'fstrcmp';

my %scan_msg;
my $scan_app;
my $scan_langs;

sub scan_init {
   ($scan_app, $scan_langs) = @_;
   %scan_msg = ();
   print "Scanning ", $scan_app, ", for @$scan_langs\n";
   sql_exec "update msgid set context = '' where app = ?", $scan_app;
}

sub scan_file($$) {
   my ($path, $lang) = @_;
   local *FILE;
   print "file '$path' for '$scan_app' in '$lang'\n";
   open FILE, "<", $path or fancydie "unable to open file for scanning", "$path: $!";
   my $file;
   while(<FILE>) {
      chomp;
      while (s/[N_]_\(?"((?:[^"\\]+|\\.)+)"\)?/[TEXT]/) {
         push @{$scan_msg{$lang}{$1}}, "$path:$. $_";
      }
      $file .= $_."\n";
   }
   while ($file =~ /[N_]_\(?"((?:[^"\\]+|\\.)+)"\)?/sg) {
      push @{$scan_msg{$lang}{$1}}, "$path:(multiline)";
   }
}

sub scan_field {
   my ($dsn, $field, $lang) = @_;
   print "field $field for '$scan_app' in '$lang'\n";
   my $db = DBI->connect(@$dsn);
   my ($table, $field) = split /\./, $field;
   my $st = $db->prepare("show columns from $table like ?"); $st->execute($field);
   my $type = $st->fetchrow_arrayref;
   $type or fancydie "no such table", $table;
   $type = $type->[1];
   $st->finish;
   if ($type =~ /^(set|enum)\('(.*)'\)$/) {
      for (split /','/, $2) {
         push @{$scan_msg{$lang}{$_}}, "DB:$dsn->[0]:$table:$field:$1";
      }
   } else {
      my $st = $db->prepare("select $field from $table"); $st->execute;
      $st->bind_columns(\my($msgid));
      while ($st->fetch) {
         push @{$scan_msg{$lang}{$msgid}}, "DB:$dsn->[0]:$table:$field" if $field ne "";
      }
   }
   $db->disconnect;
}

sub fuzzy_search  {
   my($id) = @_;
   my $st = sql_exec \my($id2,$msg,$lang),
                     "select id, msg, msgstr.lang
                      from msgid, msgstr
                      where msgid.nr = msgstr.nr and msgstr.flags & 1 and msg != ''",
    my %w;
    my %best;
    while ($st->fetch) {
       my $w = fstrcmp($id, $id2);
       next if $w < $w{$lang};
       $w{$lang} = $w;
       $best{$lang} = $msg;
    }
    \%best;
}

sub scan_end {
   while (my ($lang, $v) = each %scan_msg) {
      while (my ($msg, $context) = each %$v) {
         $context = join "\n", @$context;
         my $nr = sql_fetch "select nr from msgid where id = ? and app = ? and lang = ?", $msg, $scan_app, $lang;
         unless ($nr) {
            sql_exec "insert into msgid values (NULL, ?, ?, ?, ?)",
                     $msg, $scan_app, $lang, $context;
            $nr = sql_insertid;
         }
         my $best;
         for my $lang2 (@$scan_langs) {
            next if $lang eq $lang2;
            my $msg2 = sql_fetch "select msg from msgstr where nr = ? and lang = ? and flags & 1",
                                 $nr, $lang2;
            if (!$msg2) {
               $best = fuzzy_search $msg unless $best;
               sql_exec "replace into msgstr values (?, ?, ?, ?)",
                        $nr, $lang2, "fuzzy", $best->{$lang2}||$msg;
            }
         }
         sql_exec "update msgid set context = ? where nr = ?",
                  $context, $nr;
      }
   }
   ($scan_app, $scan_lang, %scan_msg) = ();
}

sub _went {
   my ($refs, $msgid, $msgstr) = @_;
   for ($msgid, $msgstr) {
      s/"/\\"/g;
      s/\n/\\n/g;
   }

   print "#$_\n" for grep $_ ne "", split "\n", $refs;
   print "msgid \"$msgid\"\n";
   print "msgstr \"$msgstr\"\n\n";
}

sub export_po {
   my $pmod = shift;
   my $base = "$pmod->{i18ndir}/$pmod->{name}";
   mkdir $base, 0755;
   for my $lang (grep !ref$pmod->{lang}{$_}, keys %{$pmod->{lang}}) {
      my $pofile = "$base/$lang.po";
      local *POFILE;
      print "exporting $pofile...\n";
      open POFILE, ">", $pofile or die "unable to create $pofile: $!";
      my $st = sql_exec \my($context, $id, $msg),
                        "select context, id, msg from msgid, msgstr
                         where msgid.app = ? and msgid.nr = msgstr.nr and msgstr.lang = ? and msgstr.flags & 1",
                        $pmod->{name}, $lang;
      while ($st->fetch) {
         select POFILE;
         _went $context, $id, $msg;
         select STDOUT;
      }
   }
   local *POTFILE;
   my $potfile = "$base/$pmod->{name}.pot";
   print "exporting $potfile...\n";
   open POTFILE, ">", $potfile or die "unable to create $potfile: $!";
   my $st = sql_exec \my($context, $id, $lang),
                     "select context, id, lang from msgid
                      where app = ?",
                     $pmod->{name};
   while ($st->fetch) {
      select POTFILE;
      _went "$context\n,lang=$lang", $id, $msg;
      select STDOUT;
   }
}

sub export_dbm {
   my $pmod = shift;
   my $base = "$pmod->{i18ndir}/$pmod->{name}";
   mkdir $base, 0755;
   for my $lang ('default', grep !ref$pmod->{lang}{$_}, keys %{$pmod->{lang}}) {
      my $pofile = "$base/$lang.dpo";
      print "exporting $pofile...\n";
      my %db;
      tie %db, 'GDBM_File', "$pofile~", &GDBM_NEWDB|&GDBM_FAST, 0666;
      my $st = sql_exec \my($id, $msg),
                        "select id, msg from msgid, msgstr
                         where msgid.app = ? and msgid.nr = msgstr.nr and msgstr.lang = ? and msgstr.flags & 1 and msg != ''",
                        $pmod->{name}, $lang;
      while ($st->fetch) {
         $db{$id} = $msg;
      }
      untie %db;
      rename "$pofile~", $pofile;
   }
}

1;

=back

=head1 AUTHOR

Marc Lehmann <pcg@goof.com>

=cut

