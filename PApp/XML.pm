=head1 NAME

PApp::XML - pxml sections and more

=head1 SYNOPSIS

 use PApp::XML;
 # to be written

=head1 DESCRIPTION

The PApp::XML module manages XML templates containing papp xml directives
and perl code similar to phtml sections. Together with stylesheets
(L<XML::XSLT>) this can be used to almost totally seperate content from
layout. Image a database containing XML documents with customized tags.
A stylesheet can then be used to transofrm this XML document into html +
special pappxml directives that can be used to create links etc...

# to be written

=over 4

=cut

package PApp::XML;

$VERSION = 0.08;

=item new PApp::XML parameter => value...

Creates a new PApp::XML template object with the specified behaviour. It
can be used as an object factory to create new C<PApp::XML::Template>
objects.

 special        a hashref containing special => coderef pairs. If a
                special is encountered, the given coderef will be compiled
                in instead (i.e. it will be called each time the fragment
                is print'ed). The coderef will be called with a reference
                to the attribute hash, the element's contents (as a
                string) and the PApp::XML::Template object used to print
                the string.

                If a reference to a coderef is given (e.g. C<\sub {}>),
                the coderef will be called during parsing and the
                resulting string will be added to the compiled subroutine.
                The arguments are the same, except that the contents are
                not given as string but as a magic token that must be
                inserted into the return value.

                The return value is expected to be in "phtml"
                (L<PApp::Parser>) format, the magic "contents" token must
                not occur in code sections.
                
 html           html output mode enable flag

At the moment there is one predefined special named C<slink>, that maps
almost directly into a call to slink (a leading underscore in an attribute
name gets changed into a minus (C<->) to allow for one-shot arguments),
e.g:

 <pappxml:special _special="slink" module="kill" name="Bill" _doit="1">
    Do it to Bill!
 </pappxml:special>

might get changed to (note that C<module> is treated specially):

 slink "Do it to Bill!", "kill", -doit => 1, name => "Bill";

In a XSLT stylesheet one could define:

  <xsl:template match="link">
     <pappxml:special _special="slink">
        <xsl:for-each select="@*">
           <xsl:copy/>
        </xsl:for-each>
        <xsl:apply-templates/>
     </pappxml:special>
  </xsl:template>

Which defines a C<link> element that can be used like this:

  <link module="kill" name="bill" _doit="1">Kill Bill!</link>

=cut

use PApp qw(echo sublink slink current_locals);

sub new($;%) {
   my $class = shift,
   my %args = @_;
   my $self = bless {}, $class;

   $self->{attr} = delete $args{attr} || {};
   $self->{html} = delete $args{html} || {};
   $self->{special} = {
      slink => sub {
         my ($attr, $content) = @_;
         my %attr = %$attr;
         my $sublink = delete $attr{sublink};
         my @args = delete $attr{module};
         while (my ($k, $v) = each %attr) {
            $k =~ s/^_/-/;
            push @args, $k, $v;
         }
         echo $sublink eq "yes"
            ? sublink [current_locals], $content, @args
            : slink $content, @args;
      },
      %{delete $args{special} || {}},
   };

   $self;
}

=item $pappxml->dom2template($dom, {special}, key => value...)

Compile the given DOM into a C<PApp::XML::Template> object and returns
it. An additional set of specials only used to parse this dom can be
passed as a hashref (this argument is optional). Additional key => value
pairs will be added to the template's attribute hash. The template will be
evaluated in the caller's package (e.g. to get access to __ and similar
functions).

On error, nothing is returned. Use the C<error> method to get more
information about the problem.

In addition to the syntax accepted by C<PApp::Parser::phtml2perl>, this
function evaluates certain XML Elements (please note that I consider the
"pappxml" namespace to be reserved):

 pappxml:special _special="special-name" attributes...
   
   Evaluate the special with the name given by the attribute C<_special>
   after evaluating its content. The special will receive two arguments:
   a hashref with all additional attributes and a string representing an
   already evaluated code fragment.
 
 pappxml:unquote

   Expands ("unquotes") some (but not all) entities, namely lt, gt, amp,
   quot, apos. This can be easily used within a stylesheet to create
   verbatim html or perl sections, e.g.

   <pappxml:unquote><![CDATA[
      <: echo "hallo" :>
   ]]></pappxml:unquote>

   A XSLT stylesheet that converts <phtml> sections just like in papp files
   might look like this:

   <xsl:template match="phtml">
      <pappxml:unquote>
         <xsl:apply-templates/>
      </pappxml:unquote>
   </xsl:template>

=begin comment

 attr           a hasref with attribute => value pairs. These attributes can
                later be quieried and set using the C<attr> method.

=end comment

=cut
                
sub dom2template($$;%) {
   my $self = shift;
   my $dom = shift;
   my $temp = bless {
      attr => {@_},
   }, PApp::XML::Template::;
   my $package = (caller)[0];

   $temp->{code} = $temp->_dom2sub($dom, $self, $package);

   delete $temp->{attr}{special};

   if ($temp->{code}) {
      $temp;
   } else {
      # error
      ();
   }
}

=item $err = $pappxml->error

Return infortmation about an error as an C<PApp::Exception> object
(L<PApp::Exception>).

=cut

sub error {
   my $self = shift;
   $self->{error};
}

=item xml_quote $string

Quotes (and returns) the given string using CDATA so that it's contents
won't be interpreted by an XML parser.

=item xml_unquote $string

Unquotes (and returns) an XML string (by resolving it's
entities). Currently, only the named predefined xml entities and decimal
character constants are resolved. Everything else is silently ignored.

=cut

sub xml_quote {
   local $_ = shift;
   s/\]\]>/]]>]]&gt;<![CDATA[/g;
   "<![CDATA[$_]]>";
}

sub xml_unquote($) {
   local $_ = shift;
   s{&([^;]+);}{
      if (substr($1,0,1) eq "#") {
         if (substr($1,1,1) eq "x") {
            # hex not yet supported
         } else {
            chr substr $1,1;
         }
      } else {
        { gt => '>', lt => '<', amp => '&', quot => '"', apos => "'" }->{$1}
      }
   }ge;
   $_;
}

package PApp::XML::Template;

use PApp::Parser ();
use XML::DOM;

sub __dom2sub($) {   
   my $node = $_[0]->getFirstChild;

   while ($node) {
      my $type = $node->getNodeType;

      if ($type == TEXT_NODE || $type == CDATA_SECTION_NODE) {
         $_res .= $node->toString;
      } elsif ($type == ELEMENT_NODE) {
         my $name = $node->getTagName;
         my %attr;
         {
            my $attrs = $node->getAttributes;
            for (my $n = $attrs->getLength; $n--; ) {
               my $attr = $attrs->item($n);
               $attr{$attr->getName} = $attr->getValue;
            }
         }
         if (substr($name, 0, 8) eq "pappxml:") {
            if ($name eq "pappxml:special") {
               my $name = delete $attr{_special};
               my $sub = $_self->{attr}{special}{$name} || $_factory->{special}{$name};

               if (defined $sub) {
                  my $idx = @$_local;
                  if (ref $sub eq "REF") {
                     push @$_local, $_self->_dom2sub($node, $_factory, $_package);
                     $_res .= $$sub->(
                           \%attr,
                           '<:$_dom2sub_local['.($idx).']():>',
                           $_self,
                     );
                  } else {
                     push @$_local, $sub;
                     push @$_local, \%attr;
                     push @$_local, $_self->_dom2sub($node, $_factory, $_package);
                     $_res .= '<:
                        $_dom2sub_local['.($idx).'](
                              $_dom2sub_local['.($idx+1).'],
                              capture { $_dom2sub_local['.($idx+2).']() },
                              $_dom2sub_self,
                        )
                     :>';
                  }
               } else {
                  $_res .= "&lt;&lt;&lt; undefined special '$name' containing '";
                  __dom2sub($node);
                  $_res .= "' &gt;&gt;&gt;";
               }
            } elsif ($name eq "pappxml:unquote") {
               my $res = do {
                  local $_res;
                  __dom2sub($node);
                  $_res;
               };
               $_res .= PApp::XML::xml_unquote $res;
            } else {
               $_res .= "&lt;&lt;&lt; undefined pappxml element '$name' containing '";
               __dom2sub($node);
               $_res .= "' &gt;&gt;&gt;";
            }
         } else {
            $_res .= "<$name";
            while (my ($k, $v) = each %attr) {
               # we prefer single quotes, since __ and N_ do not
               $v =~ s/'/&apos;/g;
               $_res .= " $k='$v'";
            }
            my $content = do {
               local $_res;
               __dom2sub($node);
               $_res;
            };
            if ($content ne "") {
               $_res .= ">$content</$name>";
            } elsif ($_factory->{html}) {
               if ($name =~ /^br|p|hr|img|meta|base|link$/i) {
                  $_res .= ">";
               } else {
                  $_res .= "></$name>";
               }
            } else {
               $_res .= "/>";
            }
         }
      }
      $node = $node->getNextSibling;
   }
}

sub _dom2sub($$$$) : locked {
   local $_self = shift;
   local $_dom = shift;
   local $_factory = shift;
   local $_package =  shift;

   my @_dom2sub_local;
   local $_local = \@_dom2sub_local;

   local $_res;
   __dom2sub($_dom);

   my $_dom2sub_self = $_self;
   my $_dom2sub_str = <<EOC;
package $_package;
sub {
#line 1 \"anonymous PApp::XML::Template\"
${\(PApp::Parser::phtml2perl($_res))}
}
EOC
   {
      use utf8;
      $_doc2sub_str =~ tr/\x{80}-\x{ff}//UC;
   }
   my $self = $_self;
   my $sub = eval $_dom2sub_str;

   if ($@) {
      $_factory->{error} = new PApp::Exception error => $@, info => $_dom2sub_str;
      return;
   } else {
      delete $_factory->{err};
      return $sub;
   }
}

=item $template->localvar([content]) [WIZARDRY]

Create a local variable that can be used inside specials and return a
string representation of it (i.e. a magic token that represents the lvalue
of the variable when compiled). Can only be called during compilation.

=cut

sub localvar($$;$) {
   my ($self, $val) = @_;
   my $idx = @$_local;
   push @$_local, $val;
   '$_dom2sub_local['.($idx).']';
}

=item $template->gen_surl(<surl-arguments>) [WIZARDY]

Returns a string representing a perl statement returning the surl.

=cut

sub gen_surl($;@) {
   my $self = shift;
   my $var = $self->localvar(\@_);
   "surl(\@{$var})";
}

=item $template->gen_slink(<surl-arguments>) [WIZARDY]

Returns a string representing a perl statement returning the slink.

=cut

sub gen_slink($;@) {
   my $self = shift;
   my $content = $self->localvar(shift);
   my $surl = $self->gen_surl($content);
   "slink($content, $surl)";
}

=item $template->attr(key, [newvalue])

Return the attribute value for the given key. If C<newvalue> is given, replaces
the attribute and returns the previous value.

=cut

sub attr($$;$) {
   my $self = shift;
   my $key = shift;
   my $val = $self->{attr}{$key};
   $self->{attr}{$key} = shift if @_;
   $val;
}

=item $template->print

Print (and execute any required specials). You can capture the output
using the C<PApp::capture> function. The output will be in iso-8859-1, not
utf8, as one might expect.

=cut

sub print($) {
   shift->{code}();
}

1;

=back

=head1 WIZARD EXAMPLE

In this section I'll try to sketch out a "wizard example" that shows how
C<PApp::XML> could be used in the real world.

Consider an application that fetches most or all content (even layout)
from a database and uses a stylesheet to map xml content to html, which
allows for almost total seperation of layout and content. It would have an
init section loading a XSLT stylesheet and defining a content factory:

   use XML::XSLT; # ugly module, but it works great!
   use PApp::XML;

   # create the parser
   my $xsl = "$PApp::Config{LIBDIR}/stylesheet.xsl";
   $xslt_parser = XML::XSLT->new($xsl, "FILE");

   # create a content factory
   $tt_content_factory = new PApp::XML
      html => 1, # we want html output
      special => {
         include => sub {
            my ($attr, $content) = @_;
            get_content($attr->{name})->print;
         },
      };

   # create a cache (XSLT is quite slow)
   use Tie::Cache;
   tie %content_cache, Tie::Cache::, { MaxCount => 30, WriteSync => 0};

Here we define an C<include> special that inserts another document
inplace. How does C<get_content> (see the definition of C<include>) look
like?

   <macro name="get_content" args="$name $special"><phtml><![CDATA[<:
      my $cache = $content_cache{"$lang\0$name"};
      unless ($cache) {
         $cache = $content_cache{"$lang\0$name"} = [
            undef,
            0,
         ];
      }
      if ($cache->[1] < time) {
         $cache->[0] = fetch_content $name, $special;
         $cache->[1] = time + 10;
      }
      $cache->[0];
   :>]]></phtml></macro>

C<get_content> is nothing more but a wrapper around C<fetch_content>. It's
sole purpose is to cache documents since parsing and transforming a xml
file is quite slow (please note that I include the current language when
caching documents since, of course, the documents get translated). In
non-speed-critical applications you could just substitute C<fetch_content>
for C<get_content>:

   <macro name="fetch_content" args="$name $special"><phtml><![CDATA[<:
      sql_fetch \my($id, $_name, $ctime, $body),
                "select id, name, unix_timestamp(ctime), body from content where name = ?",
                $name;
      unless ($id) {
         ($id, $_name, $ctime, $body) =
            (undef, undef, undef, "");
      }

      parse_content (gettext$body, {
         special => $special,
         id      => $id,
         name    => $name,
         ctime   => $ctime,
         lang    => $lang,
      });
   :>]]></phtml></macro>

C<fetch_content> actually fetches the content string from the database. In
this example, a content object has a name (which is used to reference it)
a timestamp and a body, which is the actual document. After fetching the
content object it uses C<parse_content> to transform the xml snippet into
a perl sub that can be efficiently executed:

   <macro name="parse_content" args="$body $attr"><phtml><![CDATA[<:
      my $content = eval {
         $xslt_parser->transform_document(
             '<?xml version="1.0" encoding="iso-8859-1" standalone="no"?'.'>'.
             "<ttt_fragment>".
             $body.
             "</ttt_fragment>",
             "STRING"
         );
         my $dom = $xslt_parser->result_tree;
         $tt_content_factory->dom2template($dom, %$attr);
      };
      if ($@) {
         my $line = $@ =~ /mismatched tag at line (\d+), column \d+, byte \d+/ ? $1 : -1;
         # create a fancy error message
      }
      $content || parse_content("");
   :>]]></phtml></macro>

As you can see, it uses XSLT's C<transform_document>, which does the
string -> DOM translation for us, and also transforms the XML code through
the stylesheet. After that it uses C<dom2template> to compile the document
into perl code and returns it.

An example stylesheet would look like this:

   <xsl:template match="ttt_fragment">
      <xsl:apply-templates/>
   </xsl:template>

   <xsl:template match="p|em|h1|h2|br|tt|hr|small">
      <xsl:copy>
         <xsl:apply-templates/>
      </xsl:copy>
   </xsl:template>

   <xsl:template match="include">
      <pappxml:special _special="include" name="{@name}"/>
   </xsl:template>

   # add the earlier XSLT examples here.

This stylesheet would transform the following XML snippet:

   <p>Look at
      <link module="product" productid="7">our rubber-wobber-cake</link>
      before it is <em>sold out</em>!
      <include name="product_description_7"/>
   </p>

Which would be turned into something like this:

   <p>Look at
      <pappxml:special _special="slink" module="product" productid="7">
         our rubber-wobber-cake
      </apppxml:special>
      before it is <em>sold out</em>!
      <pappxml:special _special="include" name="product_description_7"/>
   </p>

Now go back and try to understand the above code! But wait! Consider that you
had a content editor installed as the module C<content_editor>, as I happen to have. Now
lets introduce the C<editable_content> macro:

   <macro name="editable_content" args="$name %special"><phtml><![CDATA[<:

      my $content;

      :>
   #if access_p "admin"
      <table border=1><tr><td>
      <:
         sql_fetch \my($id), "select id from content where name = ?", $name;
         if ($id) {
            :><?sublink [current_locals], __"[Edit the content object \"$name\"]", "content_editor_edit", contentid => $id:><:
         } else {
            :><?sublink [current_locals], __"[Create the content object \"$name\"]", "content_editor_edit", contentname => $name:><:
         }

         $content = get_content($name,\%special);
         $content->print;
      :>
      </table>
   #else
      <:
         $content = get_content($name,\%special);
         $content->print;
      :>
   #endif
      <:

      return $content;
   :>]]></phtml></macro>

What does this do? Easy: If you are logged in as admin (i.e. have the
"admin" access right), it displays a link that lets you edit the object
directly. As normal user it just displays the content as-is. It could be
used like this:

   <perl><![CDATA[
      header;
      my $content = editable_content("homepage");
      footer last_changed => $content->ctime;
   ]]></perl>

Disregarding C<header> and C<footer>, this would create a page fully
dynamically out of a database, together with last-modified information,
which could be edited on the web. Obviously this approach could be
extended to any complexity.

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

