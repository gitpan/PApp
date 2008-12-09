##########################################################################
## All portions of this code are copyright (c) 2003,2004 nethype GmbH   ##
##########################################################################
## Using, reading, modifying or copying this code requires a LICENSE    ##
## from nethype GmbH, Franz-Werfel-Str. 11, 74078 Heilbronn,            ##
## Germany. If you happen to have questions, feel free to contact us at ##
## license@nethype.de.                                                  ##
##########################################################################

=head1 NAME

PApp::Parser - PApp format file parser

=head1 SYNOPSIS

=head1 DESCRIPTION

This module manages F<.papp> files (parsing, compiling etc..). You have to
look at the examples to understand the descriptions here :(

This module exports nothing (and might never do).

=over 4

=cut

package PApp::Parser;

use Carp;
use Convert::Scalar ':utf8';

use PApp::Exception;
use PApp::SQL;
use PApp::Util;
use PApp::Config;
use PApp::PCode qw(pxml2pcode xml2pcode perl2pcode pcode2pxml pcode2perl);
use PApp::XML qw(xml2utf8);
use PApp::I18n qw(normalize_langid);

no bytes;
use utf8;

$VERSION = 1.43;

=item ($ppkg, $name, $code) = parse_file $papp, $path

Parse the specified file and return the tree of nested packages ($ppkg,
the config data) and the tree containing all the (prepocessed) sourcecode
that implements the semantics ($code). $name contains the name of the
topmost (root) package.

=cut

sub parse_file {
   my $papp = shift;
   my $path = shift;

   my @curpmod; # current pmod stack
   my @curppkg; # current papp stack
   my @curend;
   my @curchr = (undef);
   my @curxsl;
   my @curfile;
   my @curwant;
   my @curdom = ['default','*'];
   my $parser;
   my $curcode;
   my @curpath;
   my @curnosession;

   my $root;
   my %code;
   my $code;

   my $lineinfo = sub {
      PApp::PCode::perl2pcode "\n;\n#line ".($_[0]->current_line)." \"$path\"\n";
   };

   my $load_fragment;

   my $handler = {
      Char => sub {
         my ($self, $cdata) = @_;
         if ($curwant[-1]) {
            $curchr[-1] .= $cdata;
         } elsif ($cdata !~ /^\s*$/) {
            $self->xpcroak("no character data allowed here");
         }
         1;
      },
      End => sub {
         #my ($self, $element) = @_;
         (pop @curend)->(pop @curchr);
         pop @curwant;
         1;
      },

      Start => sub {
         my ($self, $element, %attr) = @_;
         my $end = sub { };
         my $ppkg = $curppkg[-1];
         my $pmod = $curpmod[-1];

         push @curwant, 0;
         push @curchr, "";

         if ($element eq "package") {
            length $attr{name} > 1 or $parser->xpcroak("<package>: required attribute 'name' missing or empty");

            if ($ppkg) {
               my $pkg = new PApp::Package;
               $ppkg->{pkg}{$attr{name}} = $pkg;
               $ppkg = $pkg;
            } else {
               $root and fancydie "$path must only contain a single <package>\n";
               $ppkg = $root = new PApp::Package;
            }

            $ppkg->{domain}    = $curdom[-1][0];
            $ppkg->{name}      = $attr{name};
            $ppkg->{surlstyle} =
                 $attr{surlstyle} eq "get"   ? scalar &PApp::SURL_STYLE_GET
                                             : scalar &PApp::SURL_STYLE_URL;

            push @curppkg, $ppkg;
            push @curpath, $attr{name};
            push @curpmod, undef;

            $code = \%{$code{"/".join "/", @curpath}};

            push @apps, $ppkg unless @curppkg; #FIXME# necessary??

            #my $pmod = new PApp::Module; #FIXME# still needed?
            #$ppkg->{"/"} = $pmod;
            #push @curpmod, $pmod;

            push @curxsl, undef; # style tags don't propagate

            $end = sub {
               $code->{body} .= pcode2perl $_[0];
               pop @curppkg;
               pop @curpmod;
               pop @curpath;
               pop @curxsl;
               $code = \%{$code{"/".join "/", @curpath}} if @curpath; #FIXME# better use a stack?
            };

            if (defined $attr{src}) {
               # this is merely an include
               my $src = PApp::Util::find_file $attr{src}, ["papp"], URI->new_abs (".", $path);
               eval { $load_fragment->($src) };
               $@ and fancydie "file '$attr{src}', included in line ".$self->current_line, $@;
            }

         } elsif ($element eq "domain") {
            @curppkg or $self->xpcroak("<$element> found outside any package (not yet supported)");
            push @curdom, [$attr{name} || $ppkg->{name}, normalize_langid($attr{lang} || "*")];
            $ppkg->{domain} = $curdom[-1][0];
            push @{$ppkg->{langs}}, split /[ \t\n,]/, $curdom[-1][1];
            $papp->{file}{$path}{domain} = $curdom[-1][0];
            $papp->{file}{$path}{lang}   = $curdom[-1][1];
            $end = sub {
               $curchr[-1] .= $_[0];
               pop @curdom;
            };

         } elsif ($element eq "style") {
            $attr{src} or $attr{expr} or $self->xpcroak("<style> requires either a src or an expr attribute");

            my $type  = $attr{type};
            my $eval  = $attr{eval}  || "onload";
            my $apply = $attr{apply} || "onload";

            my $xsl;

            if (defined $attr{src}) {
               if ($type eq "pxml" and $eval ne "onload") {
                  $self->xpcroak("<style>.pxml: unsupported value for eval attribute ('$eval')");
               }

               $xsl = $ppkg->load_stylesheet($attr{src}, $type, $papp->{file}{$path}{lang});
            } else {
               my $li = pcode2perl $lineinfo->($parser);
               $xsl = "do { $li$attr{expr} }";
            }

            push @curxsl, [$xsl, $eval, $apply];

            $end = sub {
               $curchr[-1] .= $_[0];
               pop @curxsl;
            };

         } elsif ($element eq "module") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            $pmod and $self->xpcrroak("<$element> found inside another module (but modules are not nestable)");
            exists $attr{name} or $self->xpcroak("<module>: required atribute 'name' missing");

            my $name = $attr{name};

            defined $src and $self->xpcroak("<module>: attributes name and src are currently mutually exclusive");
            $attr{defer} and $self->xpcroak("<module>: defer not yet implemented");
            exists $ppkg->{module}{$name} and $self->xpcroak("<module name='$name'> already declared");

            $pmod = $ppkg->{module}{$name} = {
               name => $name, #FIXME#only needed for mark_statekey(local)
            };
            $pmod->{nosession} = $attr{nosession} if defined $attr{nosession};
	    $pmod->{nosession} = $curnosession[-1] if @curnosession;
            push @curpmod, $pmod;

            $end = sub {
               my $data = $_[0];
               delete $pmod->{name}; #FIXME# maybe name could come handy?
               if ($src) {
                  $self->xpcroak("<module>: no content allowed if src attribute used") if $data !~ /^\s*$/;
               } else {
                  if ($curxsl[-1]) {
                     my ($xslt, $eval, $apply) = @{$curxsl[-1]};

                     # xslt can be a string (== eval to get var)

                     if ($apply eq "onload") {
                        $data = $ppkg->xslt_transform($name, ref $xslt ? $xslt : eval $xslt, $data);
                     } elsif ($apply eq "output") {
                        my $xslt    = ref $xslt ? $ppkg->gen_lexical($xslt) : $xslt;
                        my $package = $ppkg->gen_lexical($ppkg);
                        my $name    = $ppkg->gen_lexical($name);
                        $data = perl2pcode('
                           $PApp::output .= do {
                              local $PApp::output = "";
                        ') . $data . perl2pcode("
                              $package->xslt_transform($name, $xslt, \$PApp::output);
                           }
                        ");
                     } else {
                        $self->xpcroak("<style>: unsupported value for apply attribute ('$apply')");
                     }
                  }
                  $code->{module}{$name} = pcode2perl $data;

               }
               pop @curpmod;
               undef $pmod;
            };

         } elsif ($element eq "nosession") {
            defined $attr{target} or $self->xpcroak("<nosession>: required attribute 'target' missing");

	    push @curnosession, $attr{target};

	    $end = sub {
	       pop @curnosession;
               $curchr[-1] .= $_[0];
	    };

         } elsif ($element eq "include") {
            $attr{src} or $self->xpcroak("<include>: required attrbiute 'src' missing");

            my $src = PApp::Util::find_file $attr{src}, ["papp"], URI->new_abs(".", $path)
               or $self->xpcroak("<include>: src file '$attr{src}' not found");

            $load_fragment->($src);

            $end = sub {
               $curchr[-1] .= $_[0];
            };

         } elsif ($element eq "import") {
            @curppkg or $self->xpcroak("<$element> found outside any package");

            if ($attr{pm}) {
               my $li = $lineinfo->($parser);
               $curwant[-1] = 1;
               $end = sub {
                  my $use = "use $attr{pm}";
                  if ($attr{pm} !~ /\s/ && $_[0] =~ /\S/) {
                     if ($_[0] =~ /^\s*\(\)\s*$/) {
                        $use .= " ()";
                     } else {
                        $use .= " qw($_[0])";
                     }
                  }
                  $curchr[-1] .= $li . perl2pcode "$use;\n"
               };
            } else {
               $attr{src} or $self->xpcroak("<import>: required attribute 'src' not specified");
               $attr{export} eq "yes" and $self->xpcroak("<import>: attribute export=yes currently unsupported");#FIXME#NYI
               my $path = PApp::Util::find_file $attr{src}, ["papp"], $path;
               defined $path or $self->xpcroak("<import>: imported file '$attr{src}' not found");
               $ppkg->{import}{$path}++;
            }

         } elsif ($element eq "macro") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            defined $attr{name} or $self->xpcroak("<macro>: required attribute 'name' not specified");
            my ($prototype, $args, $attrs);
            $prototype = $1 if $attr{name} =~ s/(\(.*\))$//;
            if ($attr{args}) {
               $args = "my (".(join ",", split /\s+/, $attr{args}).") = \@_;";
            }
            if ($attr{attrs}) {
               $attrs = " : ".$attr{attrs};
            }
            push @{$ppkg->{export}}, $attr{name} if $attr{name} =~ s/\*$//;
            $curwant[-1] = 1;
            $end  = sub {
               $curchr[-1] .= (perl2pcode "sub $attr{name}$prototype$attrs { $args\n") .
                              $_[0] .
                              (perl2pcode "\n}\n");
            };

         } elsif ($element eq "phtml" or $element eq "pxml") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            my $li = $lineinfo->($parser);
            $curwant[-1] = 1;
            $end = sub {
               $curchr[-1] .= $li . pxml2pcode shift;
            };

         } elsif ($element eq "xperl") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            my $li = $lineinfo->($parser);
            $curwant[-1] = 1;
            $end = sub {
               my $code = shift;
               {
                  no utf8; # DEVEL7952 workaround
                  use bytes; # DEVEL9916 workaround && faster
                  $code =~ s{(?<!\w)sub (\w+)\*(?=\W)}{
                     push @{$ppkg->{export}}, $1; "sub $1 "
                  }eg;
               }
               $curchr[-1] .= $li . perl2pcode $code;
            };

         } elsif ($element eq "perl") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            my $li = $lineinfo->($parser);
            $curwant[-1] = 1;
            $end = sub {
               $curchr[-1] .= $li . perl2pcode shift;
            };

         } elsif ($element eq "callback") {
            @curppkg or $self->xpcroak("<$element> found outside any package");

            if (exists $attr{type} && !exists $attr{name}) {
               # borken, not really up-to-date
               $attr{type} =~ /^(init|cleanup|childinit|childexit|newsession|newuser|request)$/
                  or $self->xpcroak("<callback>: unknown callback type '$attr{type}' specified");

               $end = sub {
                  push @{$code->{cb}{$attr{type}}}, pcode2perl shift;
               }
            } elsif (!exists $attr{type} && exists $attr{name}) {
               $pmod and $self->xpcroak("<$element> inside <module>'s are not yet implemented");

               my $args;
               my $set = "\$ppkg->{callback}{$attr{name}}";
               my $name = $ppkg->gen_lexical("$path:$ppkg->{name}:$attr{name}");

               if ($attr{args}) {
                  $args = "my (".(join ",", split /\s+/, $attr{args}).") = \@_;";
               }

               $end = sub {
                  $code->{body} .= "$set = PApp::Callback::register_callback(sub { $args\n".
                     pcode2perl(shift).
                     "\n}, name => $name);\n\n";
               }
            } else {
               $self->xpcroak("<$element>: exactly one of the attributes 'type' or 'name' must be specified");
            }

         } elsif ($element eq "state") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            defined $attr{keys} or $self->xpcroak("<state>: required attribute 'keys' is missing");
            while (my ($attr, $value) = each %attr) {
               for (split / /, $attr{keys}) {
                  $ppkg->mark_statekey($_, $attr, $pmod->{name}) if $value eq "yes";
               }
            }

         } elsif ($element eq "database") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            $ppkg->set_database(new PApp::SQL::Database
                  "papp_parser",
                  ($attr{dsn}      || ""),
                  ($attr{username} || ""),
                  ($attr{password} || ""),
            );

         } elsif ($element eq "description") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            $curwant[-1] = 1;
            #FIXME# per-module per-app per-package descriptions??
            $end = sub {
               $ppkg->{description} .= shift;
            }

         } elsif ($element eq "translate") {
            @curppkg or $self->xpcroak("<$element> found outside any package");
            for (split /\s+/, $attr{fields}) {
               my $langs = $attr{lang} || $curdom[-1][1];
               push @{$ppkg->{langs}}, split /[ \t\n,]/, $langs;
               $papp->{translate}{$_} = [
                  $ppkg->{database},
                  $curdom[-1][0],
                  $langs,
                  $attr{style} || "plain"
               ];
            }

         } elsif ($element eq "language") {
	    warn("element <language> is deprecated and does no longer serve any purpose, while parsing $path\n");

         } elsif ($element eq "fragment") {
            # empty semantics
            $end = sub {
               $curchr[-1] .= $_[0];
            };

         } else {
            $self->xpcroak("Element '$element' not recognized");
         }

         push @curend, $end;
         1;
      },
   };

   $load_fragment = sub {
      my ($_parser, $_path, $_line)  = ($parser, $path);

      require XML::Parser::Expat;

      $path = $_[0];

      $parser = new XML::Parser::Expat(
         ErrorContext  => 0,
         ParseParamEnt => 0,
         Namespaces    => 1,
      );
      $parser->setHandlers(%$handler);

      $papp->{file}{$path}{mtime}  = (stat $path)[9];
      $papp->{file}{$path}{domain} = $curdom[-1][0];
      $papp->{file}{$path}{lang}   = $curdom[-1][1];

      eval {
         my $file = do { local(*X,$/); open X, "<", $path or fancydie "$path: $!\n"; <X> };

         my ($version, $encoding, $standalone) = xml2utf8($file);

         $file = "<?xml version='$version' encoding='$encoding' standalone='$standalone'?>".
                 "<!DOCTYPE fragment SYSTEM \"/root/src/Fluffball/papp.dtd\">".
                 "<fragment xmlns='$PApp::xmlnspapp'>".
                 $file.
                 "</fragment>";

         local $SIG{__DIE__} = \&PApp::Exception::diehandler;
         $parser->parse($file);
      };

      my $error = $@;

      $parser->release;

      ($parser, $path) = ($_parser, $_path);

      fancydie "parse error while parsing $_[0]:", $error if $error;
   };

   $load_fragment->($path);

   $root or fancydie "$path did not contain any <package>s\n";

   ($root, \%code);
}

1;

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

