package PApp::I18n;

=head1 NAME

PApp::I18n - internationalization support for PApp

=head1 SYNOPSIS

   use PApp::I18n;

   my $translator = open_translator "/libdir/i18n/myapp", qw(de en);
   my $table = $translator->get_language("uk,de,en"); # will return de translator
   print $table->gettext("yeah"); # better define __ and N_ functions

=head1 DESCRIPTION

This module provides basic translation services, .po-reader and writer
support and text and database scanners to identify tagged strings.

=cut

no warnings;

use File::Glob;

use PApp::Exception;

BEGIN {
   require Exporter;

   $VERSION = 0.08;
   @ISA = qw(Exporter);
   @EXPORT = qw(
         open_translator
   );
   @EXPORT_OK = qw(
         scan_file scan_init scan_end scan_field export_po export_dbm
   );

   require XSLoader;
   XSLoader::load PApp::I18n, $VERSION;
}

our @table_registry;

=head2 TRANSLATION SUPPORT

=over 4

=item open_translator $path, lang1, lang2...

Open an existing translation directory. A translation directory can
contain any number of language translation tables. The additional
arguments must list all translations one is interested in. The translator
will always choose a translation table in this list. (In future versions
this might be autodetected).

=cut

sub open_translator {
   my ($path, @langs) = @_;
   new PApp::I18n path => $path, langs => \@langs;
}

sub new {
   my $class = shift;
   my $self = { @_ };
   bless $self, $class;
   push @table_registry, PApp::weaken(my $wref = $self);
   $self;
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

   for (split /,/, $langs) {
      $lang = $_; $lang =~ s/^\s+//; $lang =~ s/\s+$//; $lang =~ y/-/_/;
      next unless $lang;
      return $lang if exists $lang{$lang};
      $lang =~ s/_.*$//;
      return $lang if exists $lang{$lang};
      for (keys %lang) {
         if (/^${lang}_/) {
            return $_;
         }
      }
   }
   ();
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
      #my @langs = map { s/^.*\///; s/\.dpo$//; $_ } File::Glob::glob "$self->{path}/*.dpo", GLOB_NOSORT;
      $self->{lang}{$langs} = $lang = expand_lang $langs, @{$self->{langs}};
   }
   # then map the lang into the corresponding .dpo file
   my $db = $self->{db}{$lang};
   unless ($db) {
      my $path = "$self->{path}/$lang.dpo";
      $self->{db}{$lang} = $db = new PApp::I18n::Table -r $path ? $path : ();
      $db or fancydie "unable to open translation table '$lang'", "in directory '$self->{path}'";
   }
   ($lang, $db);
}

=item $translation = $table->gettext($msgid)

Find the translation for $msgid, or return the original string if no
translation is found. If the msgid starts with the two characters "\"
and "{", then these characters and all remaining characters until the
closing '}' are skipped before attempting a translation. If you do want
to include these two characters at the beginning of the string, use the
sequence "\{\{". This can be used to specify additional arguments to some
translation steps (like the language used). Here are some examples:

  string      =>    translation
  \{\string   =>    \translation
  \{\{string  =>    \{translation
  \{}string   =>    translation

To assure that the string is translated "as is" just prefix it with "\{}".

=cut

=item flush_cache

Flush the translation table cache. This is rarely necessary, translation
hash files are not written to. This can be used to ensure that new calls
to C<get_language>

=cut

sub flush_cache {
   if (@_) {
      my $self = shift;
      delete $self->{db};
   } else {
      my @tables = @table_registry;
      @table_registry = ();
      for(@tables) {
         if ($_) {
            push @table_registry, $_;
            $_->flush_cache;
         }
      }
   }
}

#############################################################################

use PApp::SQL;
use String::Similarity 'fstrcmp';

=back

=head2 SCANNING SUPPORT

As of yet undocumented

=over 4

=cut

# our because of my due to mod_perl bugs
our %scan_msg;
our $scan_app;
our $scan_langs;

=item scan_init

=cut

sub scan_init {
   ($scan_app, $scan_langs) = @_;
   %scan_msg = ();
   print "Scanning ", $scan_app, ", for @$scan_langs\n";
   sql_exec "update msgid set context = '' where app = ?", $scan_app;
}

=item scan_str $prefix, $string, $lang

=cut

sub scan_str($$$) {
   my ($prefix, $string, $lang) = @_;
   my $line = 1;
   # macintoshes not supported, but who cares ;-<
   local $_ = $string;
   for(;;) {
      if (m/\G([^\012_]*[N_]_\(?"((?:[^"\\]+|\\.)+)"\)?[^\012_]*)/sgc) {
         my ($context, $id) = ($1, $2);
         push @{$scan_msg{$lang}{$id}}, "$prefix:$line $context";
         $line += $context =~ y%\012%%;
      } elsif (m/\G\012/sgc) {
         $line++;
      } elsif (m/\G(.)/sgc) {
         # if you think this is slow then consider the first pattern
      } else {
         last;
      }
   }
}

=item scan_init

=cut

sub scan_file($$) {
   my ($path, $lang) = @_;
   local *FILE;
   print "file '$path' for '$scan_app' in '$lang'\n";
   open FILE, "<", $path or fancydie "unable to open file for scanning", "$path: $!";
   local $/;
   scan_str($path, scalar<FILE>, $lang);
}

=item scan_field $dsn, $field, $style, $lang

=cut

sub scan_field {
   my ($dsn, $field, $style, $lang) = @_;
   my $table;
   print "field $field for '$scan_app' in '$lang'\n";
   my $db = DBI->connect(@$dsn);
   ($table, $field) = split /\./, $field;
   my $st = $db->prepare("show columns from $table like ?"); $st->execute($field);
   my $type = $st->fetchrow_arrayref;
   $type or fancydie "no such table", "$table.$field";
   $type = $type->[1];
   $st->finish;
   if ($type =~ /^(set|enum)\('(.*)'\)$/) {
      for (split /','/, $2) {
         push @{$scan_msg{$lang}{$_}}, "DB:$dsn->[0]:$table:$field:$1";
      }
   } else {
      my $st = $db->prepare("select $field from $table"); $st->execute;
      $st->bind_columns(\my($msgid));
      my $prefix = "DB:$dsn->[0]:$table:$field";
      while ($st->fetch) {
         if ($style eq "code"
             or ($style eq "auto"
                 and $msgid =~ /[_]_"(?:[^"\\]+|\\.)+"/s)) {
            scan_str "$prefix $msgid", $msgid, $lang;
         } else {
            push @{$scan_msg{$lang}{$msgid}}, $prefix;
         }
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

=item scan_end

=cut

sub scan_end {
   my $refine = shift() ? " and flags & 1 = 1" : "";
   my $st1 = $PApp::SQL::DBH->prepare("select nr from msgid where id = ? and app = ? and lang = ?");
   my $st2 = $PApp::SQL::DBH->prepare("select msg from msgstr where nr = ? and lang = ?$refine");
   while (my ($lang, $v) = each %scan_msg) {
      while (my ($msg, $context) = each %$v) {
         $context = join "\n", @$context;
         $st1->execute($msg, $scan_app, $lang);
         $st1->bind_columns(\my($nr));
         $st1->fetch;
         unless ($nr) {
            sql_exec "insert into msgid values (NULL, ?, ?, ?, ?)",
                     $msg, $scan_app, $lang, $context;
            $nr = sql_insertid;
         }
         my $best;
         for my $lang2 (@$scan_langs) {
            next if $lang eq $lang2;
            $st2->execute($nr, $lang2);
            my ($msg2) = $st2->fetchrow_array;
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

=item export_po $pmod

=cut

sub export_po {
   my $pmod = shift;
   my $base = "$pmod->{i18ndir}/$pmod->{name}";
   mkdir $base, 0755;
   for my $lang (grep !ref$pmod->{lang}{$_}, keys %{$pmod->{lang}}) {
      my $pofile = "$base/$lang.po";
      local *POFILE;
      open POFILE, ">", $pofile or die "unable to create $pofile: $!";
      my $st = sql_exec \my($context, $id, $msg),
                        "select context, id, msg from msgid, msgstr
                         where msgid.app = ? and msgid.nr = msgstr.nr and msgstr.lang = ? and msgstr.flags & 1",
                        $pmod->{name}, $lang;
      if ($st->rows) {
         my $po = PApp::I18n::PO_Writer->new($pofile);
         while ($st->fetch) {
            $po->add($id, $msg, ",lang=$lang", map ":$_", split /\n/, $context);
         }
         print "exported $pofile\n";
      } else {
         unlink $pofile;
      }
   }
   local *POTFILE;
   my $potfile = "$base/$pmod->{name}.pot";
   my $st = sql_exec \my($context, $id, $lang),
                     "select context, id, lang from msgid
                      where app = ?",
                     $pmod->{name};
   if ($st->rows) {
      my $po = PApp::I18n::PO_Writer->new($potfile);
      while ($st->fetch) {
         $po->add($id, "", ",lang=$lang", map ":$_", split /\n/, $context);
      }
      print "exported $potfile\n";
   } else {
      unlink $potfile;
   }
}

=item export_dbm $pmod

=cut

sub export_dbm {
   my $pmod = shift;
   my $base = "$pmod->{i18ndir}/$pmod->{name}";
   mkdir $base, 0755;
   for my $lang (grep !ref$pmod->{lang}{$_}, keys %{$pmod->{lang}}) {
      mkdir $base, 0755 unless -e $base;
      my $pofile = "$base/$lang.dpo";
      my $st = sql_exec \my($id, $msg),
                        "select id, msg from msgid, msgstr
                         where msgid.app = ? and msgid.nr = msgstr.nr and msgstr.lang = ? and msgstr.flags & 1 and msg != ''",
                        $pmod->{name}, $lang;
      my $rows = $st->rows;
      if ($rows) {
         my $prime = int ($rows * 4 / 3) | 1;
         {
            use integer;

            NUM:
            for (;; $prime += 2) {
               my $max = int sqrt $prime;
               for (my $i = 3; $i <= $max; $i += 2) {
                  next NUM unless $prime % $i;
               }
               last;
            }
         }
         my $dpo = new PApp::I18n::DPO_Writer "$pofile~", $prime;
         while ($st->fetch) {
            next if $id eq $msg or $msg =~ /^\s+$/;
            $dpo->add($id,$msg);
         }
         undef $dpo;
         rename "$pofile~", $pofile;
         print "exported $pofile\n";
      } else {
         unlink $pofile;
      }
   }
}

sub quote {
   no bytes;
   local $_ = shift;
   s/\"/\\"/g;
   s/\n/\\n/g;
   s/\r/\\r/g;
   s/\t/\\t/g;
   s/[\x00-\x1f\x80-\x9f]/sprintf "\\x%02x", unpack "c", $1/ge;
   #s/[\x{0100}-\x{ffff}/sprintf "\\x{%04x}", ord($1)/ge;
   s/\\/\\\\/g;
   $_;
}

sub unquote {
   no bytes;
   local $_ = shift;
   s/\\\\/\\/g;
   s/\\"/\"/g;
   s/\\n/\n/g;
   s/\\r/\r/g;
   s/\\t/\t/g;
   s/\\x([0-9a-fA-F]{2,2})/pack "c", hex($1)/ge;
   s/\\x\{([0-9a-fA-F]+})\}/chr(hex($1))/ge;
   $_;
}

package PApp::I18n::PO_Reader;

use Carp;

=back

=head2 PO READING AND WRITING

CLASS PApp::I18n::PO_Reader

This class can be used to read serially through a .po file. (where "po
file" is about the same thing as a standard "Portable Object" file from
the NLS standard developed by Uniforum).

=over 4

=item $po = new PApp::I18n::PO_Reader $pathname

Opens the given file for reading.

=cut

sub new {
   my ($class, $path) = @_;
   my $self;

   $self->{path} = $path;
   open $self->{fh}, "<", $path or croak "unable to open '$path' for reading: $!";

   bless $self, $class;
}

=item ($msgid, $msgstr, @comments) = $po->next;

Read the next entry. Returns nothing on end-of-file.

=cut

sub peek {
   my $self = shift;
   unless ($self->{line}) {
      do {
         chomp ($self->{line} = $self->{fh}->getline);
      } while defined $self->{line} && $self->{line} =~ /^\s*$/;
   }
   $self->{line};
}

sub line {
   my $self = shift;
   $self->peek;
   delete $self->{line};
}

sub perr {
   my $self = shift;
   croak "$_[0], at $self->{path}:$.";
}

sub next {
   my $self = shift;
   my ($id, $str, @c);

   while ($self->peek =~ /^\s*#(.*)$/) {
      push @c, $1;
      $self->line;
   }
   if ($self->peek =~ /^\s*msgid/) {
      while ($self->peek =~ /^\s*(?:msgid\s+)?\"(.*)\"\s*$/) {
         $id .= PApp::I18n::unquote $1;
         $self->line;
      }
      if ($self->peek =~ /^\s*msgstr/) {
         while ($self->peek =~ /^\s*(?:msgstr\s+)?\"(.*)\"\s*$/) {
            $str .= PApp::I18n::unquote $1;
            $self->line;
         }
      } elsif ($self->peek =~ /\S/) {
         $self->perr("expected msgstr, not ");
      } else {
         return;
      }
   } elsif ($self->peek =~ /\S/) {
      $self->perr("expected msgid");
   } else {
      return;
   }
   ($id, $str, @c);
}

package PApp::I18n::PO_Writer;

use Carp;

=back

CLASS PApp::I18n::PO_Writer

This class can be used to write a new .po file. (where "po file" is about
the same thing as a standard "Portable Object" file from the NLS standard
developed by Uniforum).

=over 4

=item $po = new PApp::I18n::PO_Writer $pathname

Opens the given file for writing.

=cut

sub new {
   my ($class, $path) = @_;
   my $self;

   $self->{path} = $path;
   open $self->{fh}, ">", $path or croak "unable to open '$path' for writing: $!";

   bless $self, $class;
}

=item $po->add($msgid, $msgstr, @comments);

Write another entry to the po file. See PO_Reader's C<next> method.

=cut

sub splitstr {
   local $_ = "\"" . PApp::I18n::quote(shift) . "\"\n";
   # do not split into multilines yet
   $_;
}

sub add {
   my $self = shift;
   my ($id, $str, @c) = @_;

   $self->{fh}->print(
      (map "#$_\n", @c),
      "msgid ", splitstr($id),
      "msgstr ", splitstr($str),
      "\n"
   );
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

