package PApp::I18n;

=head1 NAME

PApp::I18n - internationalization support for PApp

=head1 SYNOPSIS

   use PApp::I18n;

   my $translator = open_translator "/libdir/i18n/myapp", "de";
   my $table = $translator->get_table("uk,de,en"); # will return de translator
   print $table->gettext("yeah"); # better define __ and N_ functions

=head1 DESCRIPTION

This module provides basic translation services, .po-reader and writer
support and text and database scanners to identify tagged strings.

=head2 ANATOMY OF A LANGUAGE ID

A "language" can be designated by either a free-form-string (that doesn't
match the following formal definition) or a language-region code that must match the
following regex:

 /^ ([a-z][a-z][a-z]?) (?:[-_] ([a-z][a-z][a-z]?))? $/ix
     ^                  ^  ^    ^
    "two or three letter code"
                       "optionally followed by"
                          "- or _ as seperator"
                               "two or three letter code"

There is no charset indicator, as only utf-8 is supported currently. The
first part must be a two or three letter code from iso639-2/t (alpha2 or
alpha3), optionally followed by the two or three letter country/region
code from iso3166-1 and -2. Numeric region codes might be supported one day.

=cut

no warnings;
use utf8;
no bytes;

use File::Glob;
use Convert::Scalar 'weaken';
use Convert::Scalar ':utf8';

use PApp::Exception;
use PApp::SQL;
use PApp::Config;

BEGIN {
   use base 'Exporter';

   $VERSION = 0.12;
   @EXPORT = qw(
         open_translator
   );
   @EXPORT_OK = qw(
         scan_file scan_init scan_end scan_field 
         export_po export_dpo
         normalize_langid translate_langid
   );

   require XSLoader;
   XSLoader::load PApp::I18n, $VERSION;
}

my ($iso3166, $iso639) = do {
   local $/;
   split /^__SPLIT__/m, utf8_on <DATA>;
};

sub iso639_a2_a3    { $iso639 =~ /^(...)\t[^\t]*\t$_[0]\t/m ? $1 : $_[0] }
sub iso639_a3_name  { $iso639 =~ /^$_[0]\t[^\t]*\t[^\t]*\t([^\t]*)/m and $1 }

sub iso3166_a2_a3   { $iso3166 =~ /^(...)\t$_[0]\t/m ? $1 : $_[0] }
sub iso3166_a3_name { $iso3166 =~ /^$_[0]\t[^\t]*\t(.*)$/m and $1 }

our $i18ndir;

=over 4

=item set_base $path

Set the default i18n directory to C<$path>. This must be done before any
calls to C<translate_langid> or when using relative i18n paths.

=cut

sub set_base($) {
   $i18ndir = shift;
}

=item normalize_langid $langid

Normalize the language id into it's three-letter form, if possible. This
requires a grep through a few kb of text but the result is cached. The
special language code "*" is translated to "mul".

=cut

our %nlid_cache = ();

sub normalize_langid($) {
   $nlid_cache{$_[0]} ||= do {
      local $_ = lc $_[0];
      if (/^ ([a-z][a-z][a-z]?) (?:[-_] ([a-z][a-z][a-z]?))? $/ix) {
         my ($l, $c) = ($1, $2);
         $l = "mul" if $l eq "*";
         $l = iso639_a2_a3  $l if 3 > length $l;
         if ($c ne "") {
            $c = iso3166_a2_a3 $c if 3 > length $c;
            "$l\_$c";
         } else {
            $l;
         }
      } else {
         $_;
      }
   }
}

=item translate_langid $langid[, $langid]

Decode the first C<langid> into a description of itself and translate it
into the language specified by the second C<langid> (the latter does not
work yet). The output of this function also gets cached.

=cut

our %tlid_cache = ();
our $tlid_iso3166;
our $tlid_iso639;

sub translate_langid($;$) {
   $tlid_cache{"$_[0]\x00$_[1]"} ||= do {
      my ($langid, $dest) = normalize_langid(shift);
      if ($langid =~ /^ ([a-z][a-z][a-z]) (?:[-_] ([a-z][a-z][a-z]))? $/ix) {
         my ($l, $c) = ($1, $2);
         $l = iso639_a3_name $l;
         if (@_) {
            $tlid_iso639 ||= open_translator("iso639", "en");
            $l = ucfirst $tlid_iso639->get_table($_[0])->gettext($l);
         }
         if ($c) {
            $c = iso3166_a3_name $c;
            if (@_) {
               $tlid_iso3166 ||= open_translator("iso3166", "en");
               $c = ucfirst $tlid_iso3166->get_table($_[0])->gettext($c);
            }
            return "$l ($c)" if $c;
         } elsif ($l) {
            return $l;
         }
      }
      undef;
   }
}

our @table_registry;

END {
   # work around a bug perl5.6
   # it seems that global destruction (which has undefined order)
   # causes killbackrefs to fail because the weak ref is already destroyed
   undef @table_registry;
}

=back

=head2 TRANSLATION SUPPORT

=over 4

=item open_translator $path, lang1, lang2....

Open an existing translation directory. A translation directory can
contain any number of language translation tables with filenames of the
form "language.dpo". Since the translator cannot guess in which language
the source has been written you have to specify this by adding additional
language names.

=cut

sub open_translator {
   my $path = shift;
   new PApp::I18n path => $path, langs => [@_];
}

sub new {
   my $class = shift;
   my $self = { @_ };
   bless $self, $class;

   $self->{path} = "$i18ndir/$self->{path}" unless $self->{path} =~ /^\//;

   opendir local *DIR, "$self->{path}"
      and push @{$self->{langs}}, grep s/\.dpo$//, readdir *DIR;

   my %uniq; @{$self->{langs}} = grep !$uniq{$_}++,
                                    map normalize_langid($_),
                                        @{$self->{langs}};

   push @table_registry, $self;
   weaken($table_registry[-1]);
   $self;
}

=item $translator->langs

Return all languages supported by this translator (in normalized form). Can be
used to create language-selectors, for example.

=cut

sub langs {
   @{$_[0]->{langs}};
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
      $lang = normalize_langid $_; $lang =~ s/^\s+//; $lang =~ s/\s+$//; $lang =~ y/-/_/;
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

=item $table = $translator->get_table($languages)

Find and return a translator table for the language that best matches the
C<$languages>. This function always succeeds by returning a dummy trable
if no (physical) table can be found. This function is very fast in the
general case.

=cut

sub get_table {
   $_[0]->{table_cache}{$_[1]} ||= do {
      my ($self, $langs) = @_;

      # first, map the "langs" into a real language code
      $lang = expand_lang $langs, @{$self->{langs}};

      # then map the lang into the corresponding .dpo file
      my $db = $self->{db}{$lang};
      unless ($db) {
         my $path = "$self->{path}/$lang.dpo";
         $self->{db}{$lang} = $db = new PApp::I18n::Table -r $path && $path, $lang;
         $db or fancydie "unable to open translation table '$lang'", "in directory '$self->{path}'";
      }
      $db;
   }
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

To ensure that the string is translated "as is" just prefix it with "\{}".

=cut

=item flush_cache

Flush the translation table cache. This is rarely necessary, translation
hash files are not written to. This can be used to ensure that new calls
to C<get_table> get the updated tables instead of already opened ones.

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
   $tlid_cache = ();
   $nlid_cache = ();
}

#############################################################################

use PApp::SQL;

=back

=head2 SCANNING SUPPORT

As of yet undocumented

=over 4

=cut

sub quote {
   local $_ = shift;
   utf8_upgrade $_; #d# 5.7.0 fix
   s/\\/\\\\/g;
   s/\"/\\"/g;
   s/\n/\\n/g;
   s/\r/\\r/g;
   s/\t/\\t/g;
   s/[\x00-\x1f\x80-\x9f]/sprintf "\\x%02x", unpack "c", $1/ge;
   #s/[\x{0100}-\x{ffff}/sprintf "\\x{%04x}", ord($1)/ge;
   $_;
}

sub unquote {
   local $_ = shift;
   my $r;
   utf8_upgrade $_; #d# 5.7.0 fix
   s{\\(?:
      "                     (?{ $r = "\"" })
    | n                     (?{ $r = "\n" })
    | r                     (?{ $r = "\r" })
    | t                     (?{ $r = "\t" })
    | x ([0-9a-fA-F]{2,2})  (?{ $r = chr hex $1 })
    | x \{([0-9a-fA-F]+)\}  (?{ $r = chr hex $2 })
    | \\                    (?{ $r = "\\" })
    | (.)                   (?{ $r = "<unknown escape $3>" })
   )}{ $r }gex;
   $_;
}

sub reorganize_i18ndb {
   local $PApp::SQL::DBH = PApp::Config::DBH;

   my $st = sql_exec "select i.nr, s.lang
                      from msgid i, msgstr s
                      where i.nr = s.nr and i.lang = s.lang";
   while (my($nr, $lang) = $st->fetchrow_array) {
      sql_exec "delete from msgstr where nr = ? and lang = ?", $nr, $lang;
   }

   # and non-context msgstr's
   sql_exec "delete from msgid where context = ''";

   # delete msgid-less msgstr's
   my $st = sql_exec "select s.nr
                      from msgstr s left join msgid i using (nr)
                      where i.nr is null";
   while (my($nr) = $st->fetchrow_array) {
      sql_exec "delete from msgstr where nr = ?", $nr;
   }
   return;
}

=item \%trans = fuzzy_translation $string, [$domain]

Try to find a translation for the given string in the given domain (or
globally) by finding the most similar string already in the database and
return its translation(s).

=cut

sub fuzzy_translation  {
   my ($string, $domain) = @_;
   local $PApp::SQL::DBH = PApp::Config::DBH;

   require String::Similarity;

   my ($st, $nr, $id);
   if ($domain) {
      $st = sql_exec \($nr, $id, $lang, $msg),
                     "select i.nr, i.id, s.lang, s.msg
                      from msgid as i, msgstr as s
                      where i.nr = s.nr
                            and domain = ?
                            and flags & 1 != 0
                      order by nr",
                     $domain;
   } else {
      $st = sql_exec \($nr, $id, $lang, $msg),
                     "select i.nr, i.id, s.lang, s.msg
                      from msgid as i, msgstr as s
                      where i.nr = s.nr
                            and flags & 1 != 0
                      order by nr",
   }

   my %w;
   my %trans;

   # we use a minimum similarity of 0.6

   while ($st->fetch) {
      my $w = String::Similarity::fstrcmp($string, $id, $w{$lang} ||= 0.6);

      if ($w >= $w{$lang}) {
         $trans{$lang} = utf8_on $msg;
         $w{$lang} = $w;
      }
   }
   \%trans;
}

# our instead of my due to mod_perl bugs
our %scan_msg;
our $scan_app;

=item scan_init $domain, $languages

=cut

sub scan_init {
   ($scan_app) = @_;
   utf8_upgrade $scan_app;
   %scan_msg = ();
   sql_exec "update msgid set context = '' where domain = ?", $scan_app;
}

=item scan_str $prefix, $string, $lang

=cut

sub scan_str($$$) {
   my ($prefix, $string, $lang) = @_;
   my $line = 1;
   # macintoshes not supported, but who cares ;-<
   utf8_upgrade $string; # for devel7 compatibility only
   while() {
      if ($string =~ m/\G([^\012_]*[N_]_\(?"((?:[^"\\]+|\\.)+)"\)?[^\012_]*)/sgc) {
         my ($context, $id) = ($1, $2);
         push @{$scan_msg{$lang}{PApp::I18n::unquote $id}}, "$prefix:$line $context";
         $line += $context =~ y%\012%%;
      } elsif ($string =~ m/\G\012/sgc) {
         $line++;
      } elsif ($string =~ m/\G(.)/sgc) {
         # if you think this is slow then consider the first pattern
      } else {
         last;
      }
   }
}

=item scan_file

=cut

sub scan_file($$) {
   my ($path, $lang) = @_;
   local *FILE;
   print "file '$path' for '$scan_app' in '$lang'\n";
   open FILE, "<", $path or fancydie "unable to open file for scanning", "$path: $!";
   local $/;
   my $file = <FILE>;
   utf8_on $file; #d# FIXME
   scan_str($path, $file, $lang);
}

=item scan_field $dsn, $field, $style, $lang

=cut

sub scan_field {
   my ($dsn, $field, $style, $lang) = @_;
   my $table;
   print "field $field for '$scan_app' in '$lang'\n";
   my $db = $dsn->checked_dbh;
   ($table, $field) = split /\./, $field;
   my $st = sql_exec $db, "show columns from $table like ?", $field;
   my $type = $st->fetchrow_arrayref;
   defined $type or fancydie "no such table", "$table.$field";
   $type = utf8_on $type->[1];
   $st->finish;
   if ($type =~ /^(set|enum)\('(.*)'\)$/) {
      for (split /','/, $2) {
         push @{$scan_msg{$lang}{$_}}, "DB:$dsn->[0]:$table:$field:$1";
      }
   } else {
      my $st = $db->prepare("select $field from $table"); $st->execute;
      $st->bind_columns(\my($msgid));
      my $prefix = $dsn->dsn."/$table.$field";
      while ($st->fetch) {
         utf8_on $msgid;
         if ($style eq "code"
             or ($style eq "auto"
                 and $msgid =~ /[_]_"(?:[^"\\]+|\\.)+"/s)) {
            scan_str "$prefix $msgid", $msgid, $lang;
         } else {
            push @{$scan_msg{$lang}{$msgid}}, $prefix;
         }
      }
   }
}

=item scan_end

=cut

sub scan_end {
   local $PApp::SQL::DBH = PApp::Config::DBH;
   my $st0 = $PApp::SQL::DBH->prepare("select nr from msgid where id = ? and domain = ? and lang = ?");
   my $st1 = $PApp::SQL::DBH->prepare("update msgid set context = ? where nr = ?");
   while (my ($lang, $v) = each %scan_msg) {
      while (my ($msg, $context) = each %$v) {
         $context = join "\n", @$context;
         utf8_on $msg; utf8_on $lang; utf8_upgrade $context;
         $st0->execute($msg, $scan_app, $lang);
         my $nr = $st0->fetchrow_arrayref;
         if ($nr) {
            $st1->execute($context, $nr->[0]); $st1->finish;
         } else {
            $nr = sql_insertid
                     sql_exec "insert into msgid (id, domain, lang, context) values (?, ?, ?, ?)",
                              $msg, $scan_app, $lang, $context;

            # now enter existing, similar, translations
            my $trans = fuzzy_translation $msg, $scan_app;
            while (my ($lang, $str) = each %$trans) {
               sql_exec "insert into msgstr (nr, lang, flags, msg) values (?, ?, 'fuzzy', ?)",
                        $nr, $lang, $str;
            }
         }
      }
   }

   my $st = sql_exec \my($nr), "select nr from msgid where domain = ? and context = ''", $scan_app;
   while ($st->fetch) {
      sql_exec "update msgstr set flags = flags | 4 where nr = ?", $nr;
   }

   ($scan_app, $scan_lang, %scan_msg) = ();
}

=item export_dpo $domain, $path

Export translation domain C<$domain> in binary hash format to directory
C<$path>, creating it if necessary.

=cut

sub export_dpo($$;$$) {
   my ($domain, $path, $uid, $gid) = @_;
   local $PApp::SQL::DBH = PApp::Config::DBH;
   mkdir $path;
   chown $uid, $gid, $path if defined $uid;
   unlink for glob "$path/*.dpo";
   for my $lang (sql_fetchall "select distinct s.lang
                               from msgid i, msgstr s
                               where i.domain = ? and i.nr = s.nr",
                              $domain) {
      my $pofile = "$path/$lang.dpo";
      my $st = sql_exec \my($id, $msg),
                        "select id, msg
                         from msgid i, msgstr s
                         where i.domain = ? and i.nr = s.nr and s.lang = ?
                               and s.flags & 1 and msg != ''",
                        $domain, $lang;
      my $rows = $st->rows;
      print "$pofile: $rows\n";#d#
      if ($rows) {
         my $prime = int ($rows * 4 / 3) | 1;
         {
            use integer;

            outer:
            for (;; $prime += 2) {
               my $max = int sqrt $prime;
               for (my $i = 3; $i <= $max; $i += 2) {
                  next outer unless $prime % $i;
               }
               last;
            }
         }
         my $dpo = new PApp::I18n::DPO_Writer "$pofile~", $prime;
         while ($st->fetch) {
            $dpo->add(utf8_on $id,utf8_on $msg) if $id ne $msg;
         }
         undef $dpo;
         chown $uid, $gid, "$pofile~" if defined $uid;
         rename "$pofile~", $pofile;
         push @files, $pofile;
      } else {
         unlink $pofile;
      }
   }
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
         Convert::Scalar::utf8_on $self->{line};
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
   if (s/\\n(..)/\\n"\n"$1/g) {
      $_ = "\"\"\n" . $_;
   }
   $_;
}

sub add {
   my $self = shift;
   my ($id, $str, @c) = @_;
   Convert::Scalar::utf8_upgrade $id; #d# 5.7.0 fix
   Convert::Scalar::utf8_upgrade $str; #d# 5.7.0 fix

   $self->{fh}->print(
      (map "#$_\n", @c),
      "msgid ", splitstr($id),
      "msgstr ", splitstr($str),
      "\n"
   );
}

package PApp::I18n;

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

# the following data tables are originally from http://iso.plan9.de/
__DATA__
		Africa
		Eastern Africa
		Middle Africa
		Northern Africa
		Southern Africa
		Western Africa
		Americas
		Latin America and the Caribbean
		Caribbean
		Central America
		South America
		Northern America
		Asia
		Eastern Asia
		South-central Asia
		South-eastern Asia
		Western Asia
		Europe
		Eastern Europe
		Northern Europe
		Southern Europe
		Western Europe
		Oceania
		Australia and New Zealand
		Melanesia
		Micronesia
		Polynesia
bdi	bi	Burundi
com	km	Comoros
dji	dj	Djibouti
eri	er	Eritrea
eth	et	Ethiopia
ken	ke	Kenya
mdg	mg	Madagascar
mwi	mw	Malawi
mus	mu	Mauritius
moz	mz	Mozambique
reu	re	Réunion
rwa	rw	Rwanda
syc	sc	Seychelles
som	so	Somalia
uga	ug	Uganda
tza	tz	Tanzania
zmb	zm	Zambia
zwe	zw	Zimbabwe
ago	ao	Angola
cmr	cm	Cameroon
caf	cf	Central African Republic
tcd	td	Chad
cog	cg	Congo
cod	cd	Congo
gnq	gq	Equatorial Guinea
gab	ga	Gabon
stp	st	Sao Tome and Principe
dza	dz	Algeria
egy	eg	Egypt
lby	ly	Jamahiriya
mar	ma	Morocco
sdn	sd	Sudan
tun	tn	Tunisia
esh	eh	Western Sahara
bwa	bw	Botswana
lso	ls	Lesotho
nam	na	Namibia
zaf	za	South Africa
swz	sz	Swaziland
ben	bj	Benin
bfa	bf	Burkina Faso
cpv	cv	Cape Verde
civ	ci	Cote d'Ivoire
gmb	gm	Gambia
gha	gh	Ghana
gin	gn	Guinea
gnb	gw	Guinea-Bissau
lbr	lr	Liberia
mli	ml	Mali
mrt	mr	Mauritania
ner	ne	Niger
nga	ng	Nigeria
shn	sh	Saint Helena
sen	sn	Senegal
sle	sl	Sierra Leone
tgo	tg	Togo
aia	ai	Anguilla
atg	ag	Antigua and Barbuda
abw	aw	Aruba
bhs	bs	Bahamas
brb	bb	Barbados
vgb	vg	British Virgin Islands
cym	ky	Cayman Islands
cub	cu	Cuba
dma	dm	Dominica
dom	do	Dominican Republic
grd	gd	Grenada
glp	gp	Guadeloupe
hti	ht	Haiti
jam	jm	Jamaica
mtq	mq	Martinique
msr	ms	Montserrat
ant	an	Netherlands Antilles
pri	pr	Puerto Rico
kna	kn	Saint Kitts and Nevis
lca	lc	Saint Lucia
vct	vc	Saint Vincent and the Grenadines
tto	tt	Trinidad and Tobago
tca	tc	Turks and Caicos Islands
vir	vi	Virgin Islands
blz	bz	Belize
cri	cr	Costa Rica
slv	sv	El Salvador
gtm	gt	Guatemala
hnd	hn	Honduras
mex	mx	Mexico
nic	ni	Nicaragua
pan	pa	Panama
arg	ar	Argentina
bol	bo	Bolivia
bra	br	Brazil
chl	cl	Chile
col	co	Colombia
ecu	ec	Ecuador
flk	fk	Malvinas
guf	gf	French Guiana
guy	gy	Guyana
pry	py	Paraguay
per	pe	Peru
sur	sr	Suriname
ury	uy	Uruguay
ven	ve	Venezuela
bmu	bm	Bermuda
can	ca	Canada
grl	gl	Greenland
spm	pm	Saint Pierre and Miquelon
usa	us	United States
chn	cn	China
hkg	hk	Hong Kong
mac	mo	Macao
prk	kp	Korea
jpn	jp	Japan
mng	mn	Mongolia
kor	kr	Republic of Korea
afg	af	Afghanistan
bgd	bd	Bangladesh
btn	bt	Bhutan
ind	in	India
irn	ir	Iran
kaz	kz	Kazakhstan
kgz	kg	Kyrgyzstan
mdv	mv	Maldives
npl	np	Nepal
pak	pk	Pakistan
lka	lk	Sri Lanka
tjk	tj	Tajikistan
tkm	tm	Turkmenistan
uzb	uz	Uzbekistan
brn	bn	Brunei
khm	kh	Cambodia
tmp	tp	East Timor
idn	id	Indonesia
lao	la	Lao
mys	my	Malaysia
mmr	mm	Myanmar
phl	ph	Philippines
sgp	sg	Singapore
tha	th	Thailand
vnm	vn	Viet Nam
arm	am	Armenia
aze	az	Azerbaijan
bhr	bh	Bahrain
cyp	cy	Cyprus
geo	ge	Georgia
irq	iq	Iraq
isr	il	Israel
jor	jo	Jordan
kwt	kw	Kuwait
lbn	lb	Lebanon
pse	ps	Palestine
omn	om	Oman
qat	qa	Qatar
sau	sa	Saudi Arabia
syr	sy	Syria
tur	tr	Turkey
are	ae	Arab Emirates
yem	ye	Yemen
blr	by	Belarus
bgr	bg	Bulgaria
cze	cz	Czech Republic
hun	hu	Hungary
pol	pl	Poland
mda	md	Moldova
rom	ro	Romania
rus	ru	Russia
svk	sk	Slovakia
ukr	ua	Ukraine
		Channel Islands
dnk	dk	Denmark
est	ee	Estonia
fro	fo	Faeroe Islands
fin	fi	Finland
isl	is	Iceland
irl	ie	Ireland
		Isle of Man
lva	lv	Latvia
ltu	lt	Lithuania
nor	no	Norway
sjm	sj	Svalbard and Jan Mayen Islands
swe	se	Sweden
gbr	gb	United Kingdom
alb	al	Albania
and	ad	Andorra
bih	ba	Bosnia and Herzegovina
hrv	hr	Croatia
gib	gi	Gibraltar
grc	gr	Greece
vat	va	Holy See
ita	it	Italy
mlt	mt	Malta
prt	pt	Portugal
smr	sm	San Marino
svn	si	Slovenia
esp	es	Spain
mkd	mk	Macedonia
yug	yu	Yugoslavia
aut	at	Austria
bel	be	Belgium
fra	fr	France
deu	de	Germany
lie	li	Liechtenstein
lux	lu	Luxembourg
mco	mc	Monaco
nld	nl	Netherlands
che	ch	Switzerland
aus	au	Australia
nzl	nz	New Zealand
nfk	nf	Norfolk Island
fji	fj	Fiji
ncl	nc	New Caledonia
png	pg	Papua New Guinea
slb	sb	Solomon Islands
vut	vu	Vanuatu
gum	gu	Guam
kir	ki	Kiribati
mhl	mh	Marshall Islands
fsm	fm	Micronesia
nru	nr	Nauru
mnp	mp	Mariana Islands
plw	pw	Palau
asm	as	American Samoa
cok	ck	Cook Islands
pyf	pf	French Polynesia
niu	nu	Niue
pcn	pn	Pitcairn
wsm	ws	Samoa
tkl	tk	Tokelau
ton	to	Tonga
tuv	tv	Tuvalu
wlf	wf	Wallis and Futuna Islands
		Commonwealth
twn	tw	Taiwan
	aq	Antarctica
	bv	Bouvet island
	io	British indian ocean territory
	cx	Christmas island
	cc	Cocos islands
	tf	French southern territories
	hm	Heard and McDonald islands
	yt	Mayotte
	gs	South georgia
	um	United states minor outlying islands
__SPLIT__
aar	aar	aa	Afar	Hamitic
abk	abk	ab	Abkhazian	Ibero-caucasian
ace	ace		Achinese	
ach	ach		Acoli	
ada	ada		Adangme	
afa	afa		Afro-Asiatic (Other)	
afh	afh		Afrihili	
afr	afr	af	Afrikaans	Germanic
aka	aka		Akan	
akk	akk		Akkadian	
ale	ale		Aleut	
alg	alg		Algonquian languages	
amh	amh	am	Amharic	Semitic
ang	ang		English, Old (ca. 450-1100)	
apa	apa		Apache languages	
ara	ara	ar	Arabic	Semitic
arc	arc		Aramaic	
arn	arn		Araucanian	
arp	arp		Arapaho	
art	art		Artificial (Other)	
arw	arw		Arawak	
asm	asm	as	Assamese	Indian
ath	ath		Athapascan languages	
aus	aus		Australian languages	
ava	ava		Avaric	
ave	ave	ae	Avestan	
awa	awa		Awadhi	
aym	aym	ay	Aymara	Amerindian
aze	aze	az	Azerbaijani	Turkic/altaic
bad	bad		Banda	
bai	bai		Bamileke languages	
bak	bak	ba	Bashkir	Turkic/altaic
bal	bal		Baluchi	
bam	bam		Bambara	
ban	ban		Balinese	
bas	bas		Basa	
bat	bat		Baltic (Other)	
bej	bej		Beja	
bel	bel	be	Belarusian	Slavic
bem	bem		Bemba	
ben	ben	bn	Bengali	Indian
ber	ber		Berber (Other)	
bho	bho		Bhojpuri	
bih	bih	bh	Bihari	Indian
bik	bik		Bikol	
bin	bin		Bini	
bis	bis	bi	Bislama	
bla	bla		Siksika	
bnt	bnt		Bantu (Other)	
bod	tib	bo	Tibetan	Asian
bos	bos	bs	Bosnian	
bra	bra		Braj	
bre	bre	br	Breton	Celtic
btk	btk		Batak (Indonesia)	
bua	bua		Buriat	
bug	bug		Buginese	
bul	bul	bg	Bulgarian	Slavic
cad	cad		Caddo	
cai	cai		Central American Indian (Other)	
car	car		Carib	
cat	cat	ca	Catalan	Romance
cau	cau		Caucasian (Other)	
ceb	ceb		Cebuano	
cel	cel		Celtic (Other)	
ces	cze	cs	Czech	Slavic
cha	cha	ch	Chamorro	
chb	chb		Chibcha	
che	che	ce	Chechen	
chg	chg		Chagatai	
chk	chk		Chuukese	
chm	chm		Mari	
chn	chn		Chinook jargon	
cho	cho		Choctaw	
chp	chp		Chipewyan	
chr	chr		Cherokee	
chu	chu	cu	Church Slavic	
chv	chv	cv	Chuvash	
chy	chy		Cheyenne	
cmc	cmc		Chamic languages	
cop	cop		Coptic	
cor	cor	kw	Cornish	
cos	cos	co	Corsican	Romance
cpe	cpe		Creoles and pidgins, English based (Other)	
cpf	cpf		Creoles and pidgins, French-based (Other)	
cpp	cpp		Creoles and pidgins, Portuguese-based (Other)	
cre	cre		Cree	
crp	crp		Creoles and pidgins (Other)	
cus	cus		Cushitic (Other)	
cym	wel	cy	Welsh	Celtic
dak	dak		Dakota	
dan	dan	da	Danish	Germanic
day	day		Dayak	
del	del		Delaware	
den	den		Slave (Athapascan)	
deu	ger	de	German	Germanic
dgr	dgr		Dogrib	
din	din		Dinka	
div	div		Divehi	
doi	doi		Dogri	
dra	dra		Dravidian (Other)	
dua	dua		Duala	
dum	dum		Dutch, Middle (ca. 1050-1350)	
dyu	dyu		Dyula	
dzo	dzo	dz	Dzongkha	Asian
efi	efi		Efik	
egy	egy		Egyptian (Ancient)	
eka	eka		Ekajuk	
ell	gre	el	Greek, Modern (1453-)	Latin/greek
elx	elx		Elamite	
eng	eng	en	English	Germanic
enm	enm		English, Middle (1100-1500)	
epo	epo	eo	Esperanto	International aux.
est	est	et	Estonian	Finno-ugric
eus	baq	eu	Basque	Basque
ewe	ewe		Ewe	
ewo	ewo		Ewondo	
fan	fan		Fang	
fao	fao	fo	Faroese	Germanic
fas	per	fa	Persian	
fat	fat		Fanti	
fij	fij	fj	Fijian	Oceanic/indonesian
fin	fin	fi	Finnish	Finno-ugric
fiu	fiu		Finno-Ugrian (Other)	
fon	fon		Fon	
fra	fre	fr	French	Romance
frm	frm		French, Middle (ca. 1400-1600)	
fro	fro		French, Old (842-ca. 1400)	
fry	fry	fy	Frisian	Germanic
ful	ful		Fulah	
fur	fur		Friulian	
gaa	gaa		Ga	
gay	gay		Gayo	
gba	gba		Gbaya	
gem	gem		Germanic (Other)	
gez	gez		Geez	
gil	gil		Gilbertese	
gla	gla	gd	Gaelic (Scots)	Celtic
gle	gle	ga	Irish	Celtic
glg	glg	gl	Gallegan	Romance
glv	glv	gv	Manx	
gmh	gmh		German, Middle High (ca. 1050-1500)	
goh	goh		German, Old High (ca. 750-1050)	
gon	gon		Gondi	
gor	gor		Gorontalo	
got	got		Gothic	
grb	grb		Grebo	
grc	grc		Greek, Ancient (to 1453)	
grn	grn	gn	Guarani	Amerindian
guj	guj	gu	Gujarati	Indian
gwi	gwi		Gwich´in	
hai	hai		Haida	
hau	hau	ha	Hausa	Negro-african
haw	haw		Hawaiian	
heb	heb	he	Hebrew	
her	her	hz	Herero	
hil	hil		Hiligaynon	
him	him		Himachali	
hin	hin	hi	Hindi	Indian
hit	hit		Hittite	
hmn	hmn		Hmong	
hmo	hmo	ho	Hiri Motu	
hrv	scr	hr	Croatian	Slavic
hun	hun	hu	Hungarian	Finno-ugric
hup	hup		Hupa	
hye	arm	hy	Armenian	Indo-european (other)
iba	iba		Iban	
ibo	ibo		Igbo	
ijo	ijo		Ijo	
iku	iku	iu	Inuktitut	
ile	ile	ie	Interlingue	International aux.
ilo	ilo		Iloko	
ina	ina	ia	Interlingua (International Auxiliary Language Association)	International aux.
inc	inc		Indic (Other)	
ind	ind	id	Indonesian	
ine	ine		Indo-European (Other)	
ipk	ipk	ik	Inupiaq	Eskimo
ira	ira		Iranian (Other)	
iro	iro		Iroquoian languages	
isl	ice	is	Icelandic	Germanic
ita	ita	it	Italian	Romance
jaw	jav	jw	Javanese	
jpn	jpn	ja	Japanese	Asian
jpr	jpr		Judeo-Persian	
kaa	kaa		Kara-Kalpak	
kab	kab		Kabyle	
kac	kac		Kachin	
kal	kal	kl	Kalaallisut	Eskimo
kam	kam		Kamba	
kan	kan	kn	Kannada	Dravidian
kar	kar		Karen	
kas	kas	ks	Kashmiri	Indian
kat	geo	ka	Georgian	Ibero-caucasian
kau	kau		Kanuri	
kaw	kaw		Kawi	
kaz	kaz	kk	Kazakh	Turkic/altaic
kha	kha		Khasi	
khi	khi		Khoisan (Other)	
khm	khm	km	Khmer	Asian
kho	kho		Khotanese	
kik	kik	ki	Kikuyu	
kin	kin	rw	Kinyarwanda	Negro-african
kir	kir	ky	Kirghiz	Turkic/altaic
kmb	kmb		Kimbundu	
kok	kok		Konkani	
kom	kom	kv	Komi	
kon	kon		Kongo	
kor	kor	ko	Korean	Asian
kos	kos		Kosraean	
kpe	kpe		Kpelle	
kro	kro		Kru	
kru	kru		Kurukh	
kum	kum		Kumyk	
kur	kur	ku	Kurdish	Iranian
kut	kut		Kutenai	
lad	lad		Ladino	
lah	lah		Lahnda	
lam	lam		Lamba	
lao	lao	lo	Lao	Asian
lat	lat	la	Latin	Latin/greek
lav	lav	lv	Latvian	Baltic
lez	lez		Lezghian	
lin	lin	ln	Lingala	Negro-african
lit	lit	lt	Lithuanian	Baltic
lol	lol		Mongo	
loz	loz		Lozi	
ltz	ltz	lb	Letzeburgesch	
lua	lua		Luba-Lulua	
lub	lub		Luba-Katanga	
lug	lug		Ganda	
lui	lui		Luiseno	
lun	lun		Lunda	
luo	luo		Luo (Kenya and Tanzania)	
lus	lus		lushai	
mad	mad		Madurese	
mag	mag		Magahi	
mah	mah	mh	Marshall	
mai	mai		Maithili	
mak	mak		Makasar	
mal	mal	ml	Malayalam	Dravidian
man	man		Mandingo	
map	map		Austronesian (Other)	
mar	mar	mr	Marathi	Indian
mas	mas		Masai	
mdr	mdr		Mandar	
men	men		Mende	
mga	mga		Irish, Middle (900-1200)	
mic	mic		Micmac	
min	min		Minangkabau	
mis	mis		Miscellaneous languages	
mkd	mac	mk	Macedonian	Slavic
mkh	mkh		Mon-Khmer (Other)	
mlg	mlg	mg	Malagasy	Oceanic/indonesian
mlt	mlt	mt	Maltese	Semitic
mnc	mnc		Manchu	
mni	mni		Manipuri	
mno	mno		Manobo languages	
moh	moh		Mohawk	
mol	mol	mo	Moldavian	Romance
mon	mon	mn	Mongolian	
mos	mos		Mossi	
mri	mao	mi	Maori	Oceanic/indonesian
msa	may	ms	Malay	Oceanic/indonesian
mul	mul		Multiple languages	
mun	mun		Munda languages	
mus	mus		Creek	
mwr	mwr		Marwari	
mya	bur	my	Burmese	Asian
myn	myn		Mayan languages	
nah	nah		Nahuatl	
nai	nai		North American Indian	
nau	nau	na	Nauru	
nav	nav	nv	Navajo	
nbl	nbl	nr	Ndebele, South	
nde	nde	nd	Ndebele, North	
ndo	ndo	ng	Ndonga	
nds	nds		Low German; Low Saxon; German, Low; Saxon, Low	
nep	nep	ne	Nepali	Indian
new	new		Newari	
nia	nia		Nias	
nic	nic		Niger-Kordofanian (Other)	
niu	niu		Niuean	
nld	dut	nl	Dutch	Germanic
nno	nno	nn	Norwegian Nynorsk	
nob	nob	nb	Norwegian Bokmål	
non	non		Norse, Old	
nor	nor	no	Norwegian	Germanic
nso	nso		Sotho, Northern	
nub	nub		Nubian languages	
nya	nya	ny	Chichewa; Nyanja	
nym	nym		Nyamwezi	
nyn	nyn		Nyankole	
nyo	nyo		Nyoro	
nzi	nzi		Nzima	
oci	oci	oc	Occitan (post 1500); Provençal	Romance
oji	oji		Ojibwa	
ori	ori	or	Oriya	Indian
orm	orm	om	Oromo	Hamitic
osa	osa		Osage	
oss	oss	os	Ossetian; Ossetic	
ota	ota		Turkish, Ottoman (1500-1928)	
oto	oto		Otomian languages	
paa	paa		Papuan (Other)	
pag	pag		Pangasinan	
pal	pal		Pahlavi	
pam	pam		Pampanga	
pan	pan	pa	Panjabi	Indian
pap	pap		Papiamento	
pau	pau		Palauan	
peo	peo		Persian, Old (ca. 600-400 b.c.)	
phi	phi		Philippine (Other)	
pli	pli	pi	Pali	
pol	pol	pl	Polish	Slavic
pon	pon		Pohnpeian	
por	por	pt	Portuguese	Romance
pra	pra		Prakrit languages	
pro	pro		Provençal, Old (to 1500)	
pus	pus	ps	Pushto	Iranian
que	que	qu	Quechua	Amerindian
raj	raj		Rajasthani	
rap	rap		Rapanui	
rar	rar		Rarotongan	
roa	roa		Romance (Other)	
rom	rom		Romany	
ron	rum	ro	Romanian	Romance
run	run	rn	Rundi	Negro-african
rus	rus	ru	Russian	Slavic
sad	sad		Sandawe	
sag	sag	sg	Sango	Negro-african
sah	sah		Yakut	
sai	sai		South American Indian (Other)	
sal	sal		Salishan languages	
sam	sam		Samaritan Aramaic	
san	san	sa	Sanskrit	Indian
sas	sas		Sasak	
sat	sat		Santali	
sco	sco		Scots	
sel	sel		Selkup	
sem	sem		Semitic (Other)	
sga	sga		Irish, Old (to 900)	
sgn	sgn		Sign Languages	
shn	shn		Shan	
sid	sid		Sidamo	
sin	sin	si	Sinhalese	Indian
sio	sio		Siouan languages	
sit	sit		Sino-Tibetan (Other)	
sla	sla		Slavic (Other)	
slk	slo	sk	Slovak	Slavic
slv	slv	sl	Slovenian	Slavic
sme	sme	se	Northern Sami	
smi	smi		Sami languages (Other)	
smo	smo	sm	Samoan	Oceanic/indonesian
sna	sna	sn	Shona	Negro-african
snd	snd	sd	Sindhi	Indian
snk	snk		Soninke	
sog	sog		Sogdian	
som	som	so	Somali	Hamitic
son	son		Songhai	
sot	sot	st	Sotho, Southern	Negro-african
spa	spa	es	Spanish	Romance
sqi	alb	sq	Albanian	Indo-european (other)
srd	srd	sc	Sardinian	
srp	scc	sr	Serbian	Slavic
srr	srr		Serer	
ssa	ssa		Nilo-Saharan (Other)	
ssw	ssw	ss	Swati	Negro-african
suk	suk		Sukuma	
sun	sun	su	Sundanese	Oceanic/indonesian
sus	sus		Susu	
sux	sux		Sumerian	
swa	swa	sw	Swahili	Negro-african
swe	swe	sv	Swedish	Germanic
syr	syr		Syriac	
tah	tah	ty	Tahitian	
tai	tai		Tai (Other)	
tam	tam	ta	Tamil	Dravidian
tat	tat	tt	Tatar	Turkic/altaic
tel	tel	te	Telugu	Dravidian
tem	tem		Timne	
ter	ter		Tereno	
tet	tet		Tetum	
tgk	tgk	tg	Tajik	Iranian
tgl	tgl	tl	Tagalog	Oceanic/indonesian
tha	tha	th	Thai	Asian
tig	tig		Tigre	
tir	tir	ti	Tigrinya	Semitic
tiv	tiv		Tiv	
tkl	tkl		Tokelau	
tli	tli		Tlingit	
tmh	tmh		Tamashek	
tog	tog		Tonga (Nyasa)	
ton	ton	to	Tonga (Tonga Islands)	Oceanic/indonesian
tpi	tpi		Tok Pisin	
tsi	tsi		Tsimshian	
tsn	tsn	tn	Tswana	Negro-african
tso	tso	ts	Tsonga	Negro-african
tuk	tuk	tk	Turkmen	Turkic/altaic
tum	tum		Tumbuka	
tur	tur	tr	Turkish	Turkic/altaic
tut	tut		Altaic (Other)	
tvl	tvl		Tuvalu	
twi	twi	tw	Twi	Negro-african
tyv	tyv		Tuvinian	
uga	uga		Ugaritic	
uig	uig	ug	Uighur	
ukr	ukr	uk	Ukrainian	Slavic
umb	umb		Umbundu	
und	und		Undetermined	
urd	urd	ur	Urdu	Indian
uzb	uzb	uz	Uzbek	Turkic/altaic
vai	vai		Vai	
ven	ven		Venda	
vie	vie	vi	Vietnamese	Asian
vol	vol	vo	Volapük	International aux.
vot	vot		Votic	
wak	wak		Wakashan languages	
wal	wal		Walamo	
war	war		Waray	
was	was		Washo	
wen	wen		Sorbian languages	
wol	wol	wo	Wolof	Negro-african
xho	xho	xh	Xhosa	Negro-african
yao	yao		Yao	
yap	yap		Yapese	
yid	yid	yi	Yiddish	
yor	yor	yo	Yoruba	Negro-african
ypk	ypk		Yupik languages	
zap	zap		Zapotec	
zen	zen		Zenaga	
zha	zha	za	Zhuang	
zho	chi	zh	Chinese	Asian
znd	znd		Zande	
zul	zul	zu	Zulu	Negro-african
zun	zun		Zuni	
