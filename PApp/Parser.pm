=head1 NAME

PApp::Parser - PApp format file parser

=head1 SYNOPSIS

=head1 DESCRIPTION

This module manages papp files (parsing, compiling etc..). Sorry, you have
to look at the examples to understand the descriptions here :(

This module exports nothing at the moment, but might soon export C<phtml2perl>
and other nifty functions.

=over 4

=cut

package PApp::Parser;

use Carp;
use XML::Parser::Expat;
use PApp::Exception;

$VERSION = 0.05;

=item phtml2perl "pthml-code";

Convert <phtml> code to normal perl. The following four mode-switches are
allowed, the initial mode is "?>" (i.e. interpolated html).

 <:	start verbatim perl section ("perl-mode")
 :>	start plain html section (non-interpolated html)
 <?	start perl expression (single expr, result will echo'd) (eval this!)
 ?>	start interpolated html section (similar to qq[...]>)

Within plain and interpolated html sections you can also use the
__I<>"string" construct to mark (and map) internationalized text. The
construct must be used verbatim: two underlines, one double-quote, text,
and a trailing double-quote. For more complex uses, just escape to perl
(e.g. <?__I<>"xxx"?>).

White space is preserved all over the html-sections. If you do not like
this (e.g. you want to output a png or other binary data) use perl section
instead.

In html sections (and only there!), you can also use preprocessor commands
(the C<#> must be at the beginning of the line, between the C<#> and the
command anme can be any amount of white space, just like in C!)

 #if any_perl_condition
   any phtml code
 #elif any_perl_conditon
   ...
 #else
   ...
 #endif

=for nobody
   
And also these experimental preprocessor commands (these currently trash the line number info, though!)

 #?? condition ?? if-yes-phtml-code
 #?? condition ?? if-yes-phtml-code ?? if-no-phtml-code

=cut

sub phtml2perl {
   my $data = shift;
   $data = "?>$data<:";
   my $perl;
   for ($data) {
      /[\x00-\x06]/ and croak "phtml2perl: phtml code contains  illegal control characters (\\x00-\\x06)";
      # could be improved a lot, but this is not timing-critical
      my ($n,$p, $s,$q) = ":";
      for(;;) {
         # PERL
         last unless /\G(.*?)([:?])>/sgc;
         $p = $n; $n = $2;
         if ($1 ne "") {
            if ($p eq ":") {
               $perl .= $1 . ";";
            } else {
               $perl .= '$PApp::output .= do { ' . $1 . ' }; ';
            }
         }
         # HTML
         last unless /\G(.*?)<([:?])/sgc;
         $p = $n; $n = $2;
         if ($1 ne "") {
            for ($s = $1) {
               # I use \x01 as string-delimiter (it's not whitespace...)
               if ($p eq ":") {
                  $q = "";
                  s/\\/\\\\/g;
               } else {
                  $q = "q";
               }
               # __ "text", use [_]_ so it doesn't get mis-identified by pxgettext ;)
               s/([_]_"(?:(?:[^"\\]+|\\.)*)")/\x01.($1).q$q\x01/gs;
               # preprocessor commands
               #s/^#\s*\?\?\s(.*)\?\?(.*?)(?:\?\?(.*))?$/#if 1:$1\n2:$2\n#else\n3:$3\n#endif\nXXXX/gm;
               s/^#\s*if\s(.*)$/\x01; if ($1) { \$PApp::output .= q$q\x01/gm;
               s/^#\s*elsif\s(.*)$/\x01} elsif ($1) { \$PApp::output .= q$q\x01/gm;
               s/^#\s*else\s*$/\x01} else { \$PApp::output .= q$q\x01/gm;
               s/^#\s*endif\s*$/\x01} \$PApp::output .= q$q\x01/gm;
            }
            $perl .= "\$PApp::output .= q$q\x01$s\x01; ";
         }
      }
      #print STDERR "DATA $data\nPERL $perl\n";# if $perl =~ /rating/;
   }
   $perl;
}

# PApp::Base is the superclass for all papp modules
@PApp::Base::ISA = 'Exporter';

my $upid = "PMOD000000";

sub _eval {
   # be careful not to use "my" for global variables -> my vars
   # are visible  within the subs we do!
   my $sub = eval "package $_[0]->{package};\n$_[1]\n;";

   die $@ if $@;

   #if ($@) {
   #   my $msg = $@;
   #   ($msg, $data) = @$msg if ref $msg;
   #   $data =~ s/</&lt;/g;
   #   $data =~ s/>/&gt;/g;
   #   $s = 0; $data =~ s/^/sprintf "%03d: ", ++$s/gem;
   #   send_errorpage($_[0], 'Script compilation error', $msg."<p><p><p>$data");
   #}

   $sub;
}

sub compile {
   my $pmod = shift;

   $pmod->{package} = "PApp::".++$upid;

   @{$pmod->{package}."::EXPORT"} = @{$pmod->{export}};
   @{$pmod->{package}."::ISA"} = qw(PApp::Base);
   ${$pmod->{package}."::papp_translator"} =
      PApp::I18n::open_translator("$pmod->{i18ndir}/$pmod->{name}", keys %{$pmod->{lang}});

   $pmod->_eval("
      use PApp;
      use PApp::SQL;
      use PApp::HTML;
      use PApp::Exception;

#line 1 \"(internal gettext)\"
      sub gettext(\$) {
         PApp::I18n::Table::gettext(\$papp_table, \$_[0]);
      }
      sub __(\$) {
         PApp::I18n::Table::gettext(\$papp_table, \$_[0]);
      }
   ");

   $pmod->{cb_src}{request} = "
#line 1 \"(language initialization)\"
      (\$$pmod->{package}::lang, \$$pmod->{package}::papp_table) = \$$pmod->{package}::papp_translator->get_language(\$PApp::langs);
   ".$pmod->{cb_src}{request};

   for $imp (@{$pmod->{import}}) {
      $pmod->_eval("BEGIN { import $imp->{package} }");
   }

   $pmod->_eval($pmod->{module}{init}{cb_src});

   for my $type (keys %{$pmod->{cb_src}}) {
      $pmod->{cb}{$type} = $pmod->_eval("sub {\n$pmod->{cb_src}{$type}\n}");
   }

   for my $module (@{$pmod->{modules}}) {
      next if $pmod->{module}{$module}{cb};
      next if $module eq "init";
      $pmod->{module}{$module}{cb} = $pmod->_eval("sub {\n$pmod->{module}{$module}{cb_src}\n}");
   }
}

sub mark_statekey {
   my ($pmod, $key, $attr, $extra) = @_;
   $pmod->{state}{preferences}{$key}   = 1 if $attr eq "preferences";
   $pmod->{state}{sysprefs}{$key}      = 1 if $attr eq "sysprefs";
   $pmod->{state}{import}{$key}        = 1 if $attr eq "import";
   $pmod->{state}{local}{$key}{$extra} = 1 if $attr eq "local";
}

my %import;

# parse a file _and_ put it into PApp::Config's hash
sub load_file {
   my $class = shift;
   my $path = shift;
   my $dmod = shift || "";
   my $pmod = shift || bless {
      import => [],
      cb_src => {
                   init       => "",
                   childinit  => "",
                   childexit  => "",
                   request    => "",
                   cleanup    => "",
                   newsession => "",
                   newuser    => "",
                },
      lang   => {},
      path   => $path,
      i18ndir=> $PApp::i18ndir,
      modules=> [ '' ],
      state  => { 
                   import      => { lang => 1 },
                   preferences => { },
                   sysprefs    => {
                                     lang => 1,
                                     papp_visits => 1,
                                     papp_last_cookie => 1,
                                  },
                },
      @_,
   }, __PACKAGE__;

   $pmod->{file}{$path}{mtime} = (stat $path)[9];

   my $parser = new XML::Parser::Expat(
      Namespaces => 0,
      ErrorContext => 0,
      ParseParamEnt => 0,
      Namespaces => 1,
   );

   my @curmod;
   my @curend;
   my @curchr;

   my $lineinfo = sub {
      "\n;\n#line ".($parser->current_line)." \"$path\"\n";
   };

   $parser->setHandlers(
      Char => sub {
         my ($self, $cdata) = @_;
         # convert back to latin1 (from utf8)
         {
            use utf8;
            $cdata =~ tr/\0-\x{ff}//UC;
         }
         $curchr[-1] .= $cdata;
         1;
      },
      End => sub {
         my ($self, $element) = @_;
         my $char = pop @curchr;
         (pop @curend)->($char);
         1;
      },
      Start => sub {
         my ($self, $element, %attr) = @_;
         my $end = sub { };
         push @curchr, "";
         if ($element eq "papp") {
            push @curmod, $dmod;
            $pmod->{name} = $attr{name} if defined $attr{name};
            $pmod->{domain} = $attr{name} if defined $attr{name};
            $pmod->{file}{$path}{lang} = $attr{lang} if defined $attr{lang};
            $end = sub {
               $pmod->{module}{$dmod}{cb_src} .= $_[0];
            };
         } elsif ($element eq "module") {
            #defined $attr{name} or $self->xpcroak("<module>: required attribute 'name' not specified");
            $attr{name} ||= "";#d# really?
            $attr{defer} and $self->xpcroak("<module>: defer not yet implemented");
            push @curmod, $attr{name};
            $pmod->{module}{$attr{name}}{nosession}
               = defined $attr{nosession} ? $attr{nosession} : $attr{name};
            if ($attr{src}) {
               my $path = PApp::expand_path $attr{src};
               $pmod->{file}{$path}{lang} = $pmod->{file}{$pmod->{path}}{lang};
               $self->xpcroak("<module>: external module '$attr{src}}' not found") unless defined $path;
               load_file PApp::Parser $path, $attr{name}, $pmod;
            }
            $end = sub {
               push @{$pmod->{modules}}, $attr{name};
               if ($attr{src}) {
                  $self->xpcroak("<module>: no content allowed if src attribute used") if $_[0] !~ /^\s*$/;
               } else {
                  $pmod->{module}{$attr{name}}{cb_src} = $_[0];
               }
               pop @curmod;
            };
         } elsif ($element eq "import") {
            $attr{src} or $self->xpcroak("<import>: required attribute 'src' not specified");
            my $path = PApp::expand_path $attr{src};
            defined $path or $self->xpcroak("<import>: imported file '$attr{src}' not found");
            my $imp = $import{$path};
            if ($checkdeps || !defined $imp) {
               $imp = load_file PApp::Parser $path;
               $import{$path} = $imp;
               $imp->compile;
               $imp->{module}{""}{cb}->();
            }
            while (my($k,$v) = each %{$imp->{cb_src}}) {
               $pmod->{cb_src}{$k} .= $v;
            }
            push @{$pmod->{import}}, $imp;
            if ($attr{export} eq "yes") {
               push @{$pmod->{export}}, @{$imp->{export}};
            }
         } elsif ($element eq "macro") {
            defined $attr{name} or $self->xpcroak("<macro>: required attribute 'name' not specified");
            $attr{name} =~ s/(\(.*\))$//;
            my ($prototype, $args, $attrs) = $1;
            if ($attr{args}) {
               $args = "my (".(join ",", split /\s+/, $attr{args}).") = \@_;";
            }
            if ($attr{attrs}) {
               $attrs = " : ".$attr{attrs};
            }
            push @{$pmod->{export}}, $attr{name} if $attr{name} =~ s/\*$//;
            $end  = sub {
               $curchr[-1] .= "sub $attr{name}$prototype$attrs { $args\n" . $_[0] . "\n}\n";
            };
         } elsif ($element eq "phtml") {
            my $li = &$lineinfo;
            $end = sub {
               $curchr[-1] .= $li . phtml2perl shift;
            };
         } elsif ($element eq "xperl") {
            my $li = &$lineinfo;
            $end = sub {
               my $code = shift;
               $code =~ s{(?<!\w)sub (\w+)\*(?=\W)}{
                  push @{$pmod->{export}}, $1; "sub $1"
               }meg;
               $curchr[-1] .= $li . $code;
            };
         } elsif ($element eq "perl") {
            my $li = &$lineinfo;
            $end = sub {
               $curchr[-1] .= $li . shift;
            };
         } elsif ($element eq "callback") {
            # borken, not really up-to-date
            #$attr{type} =~ /^(init|cleanup|childinit|childexit|newsession|newuser)$/ or $self->xpcroak("<callback>: unknown callback 'type' specified");
            $end = sub {
               $pmod->{cb_src}{$attr{type}} .= shift;
            }
         } elsif ($element eq "state") {
            defined $attr{keys} or $self->xpcroak("<state>: required attribute 'keys' is missing");
            while (my ($attr, $value) = each %attr) {
               for (split / /, $attr{keys}) {
                  $pmod->mark_statekey($_, $attr, $curmod[-1]) if $value eq "yes";
               }
            }
         } elsif ($element eq "database") {
            $pmod->{database} = [
               ($attr{dsn}      || ""),
               ($attr{username} || ""),
               ($attr{password} || ""),
            ];
         } elsif ($element eq "translate") {
            for (split / /, $attr{fields}) {
               $pmod->{translate}{$_} = [$attr{lang}, $attr{style}||"plain"];
            }
         } elsif ($element eq "language") {
            defined $attr{lang} or $self->xpcroak("<language>: required attribute 'lang' is missing");
            defined $attr{desc} or $self->xpcroak("<language>: required attribute 'desc' is missing");

            my $lang = $attr{lang};

            $pmod->{lang}{$lang} = $attr{desc};
            for (split / /, $attr{aliases}) {
               $pmod->{lang}{$_} = \$lang;
            }
         } else {
            $self->xpcroak("Element '$element' not recognized");
         }
         push @curend, $end;
         1;
      },
   );

   my $file = do { local(*X,$/); open X, "<", $path or die "$path: $!\n"; <X> };
   unless ($file =~ /<\/papp>\s*$/) {
      $file = "<papp>$file</papp>";
   }
   $file = "<?xml version=\"1.0\" encoding=\"iso-8859-1\" standalone=\"no\"?>".
           "<!DOCTYPE papp SYSTEM \"/root/src/Fluffball/papp.dtd\">".
           $file;

   eval { $parser->parse($file) };
   fancydie "Error while parsing file '$path':", $@ if $@;

   $pmod;
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

