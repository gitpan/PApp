package Agni;

=head1 NAME

Agni - persistent data and objects

=head1 SYNOPSIS

 * This module requires the PApp module to be installed and working     *
 * Please read the LICENSE file (Agni is neither GPL nor BSD licensed). *

=head1 DESCRIPTION

Agni is a germanic god of fire. The rest is obvious...

=cut

use utf8;

use Carp;

use PApp::Config qw(DBH $DBH $Database); DBH;

use PApp::Env;
use PApp::SQL;
use PApp::Event;
use PApp::Preprocessor;
use PApp::PCode qw(pxml2pcode perl2pcode pcode2perl);
use PApp::Callback ();
use PApp::Exception;

use Convert::Scalar ();

use base Exporter;

our $app; # current application object
our $env; # current content::environment

our %temporary; # used by the "temporary" attribute type

BEGIN {
   # I was lazy, all the util xs functions are in PApp.xs
   require XSLoader;
   XSLoader::load PApp, $VERSION unless defined &PApp::bootstrap;
}

@EXPORT = qw(
      require_path new_objectid

      %obj_cache

      path_obj_by_gid gid

      %pathid @pathname @pathmask @subpathmask @parpathmask @parpath
);

@EXPORT_OK = (@EXPORT, qw(
      *app *env
));

# packages used to provide useful compilation environment
use PApp::HTML;

our %obj_cache; # obj_cache{$gid}[$pathid]

my @agni_bootns; # boot namespace objects
my %ns_cache;    # the namespace object cache

our %pathid;      # name => id
our @parpath;     # id => id
our @pathname;    # id => name
our @pathmask;    # id => maskbit
our @subpathmask; # id => subpath mask (|| of path + all subpaths)
our @parpathmask; # id => parent path mask (|| of all parents, sans path itself)

our $last_compile_status;

# reserved object gids
# <20 == must only use string types and perl methods, for bootstrapping

$OID_OBJECT		= 1;
$OID_ATTR		= 2;
$OID_ATTR_NAMED		= 3;
$OID_METHOD		= 4;
$OID_METHOD_ARGS	= 5;
$OID_DATA		= 6;
$OID_DATA_STRING	= 7;
$OID_METHOD_PERL	= 8;
$OID_ATTR_SQLCOL	= 9;

$OID_METHOD_PXML	= 20;
$OID_META		= 21;
$OID_META_DESC		= 22;
$OID_META_NAME		= 23;
$OID_ATTR_NAME		= 24;
$OID_ATTR_CONTAINER     = 25;
$OID_DATA_REF           = 26;
$OID_IFACE_CONTAINER	= 27; # object has a gc_enum, + obj_enum methods (NYI)
$OID_META_NOTE		= 28; # notes/flags for objects
$OID_ATTR_TAG		= 29; # objects used as tags for containers
$OID_META_PACKAGE	= 30; # perl package name
$OID_INTERFACE		= 31; # class interface
$OID_ROOTSET		= 32; # a container containing all objects that are alive "by default"
$OID_CMDLINE_HANDLER    = 21474836484; # util::cmdline
$OID_META_NAMESPACE	= 4295048763;
$OID_NAMESPACE_AGNI     = 4295049779; # lots of special-casing for that one
$OID_META_PARCEL	= 5100000280;

our %BOOTSTRAP_LEVEL; # indexed by {gid}

sub UPDATE_PATHID() { 0x01 }
sub UPDATE_DATA()   { 0x02 }
sub UPDATE_CLASS()  { 0x04 }
sub UPDATE_PATHS()  { 0x08 }
sub UPDATE_ALL()    { 0x10 }

sub init_paths {
   %pathname =
   @pathid =
   @pathmask =
   @subpathmask =
   @parpathmask = ();

   # all paths, shorter ones first
   my $st = sql_exec \my($id, $mask, $name), "select id, (1 << id), path from obj_path order by path";
   while ($st->fetch) {
      $pathid{$name} = $id;
      $pathname[$id] = $name;
      $pathmask[$id] = $mask;
      $parpathmask[$id] = sql_fetch "select coalesce(sum(1 << id), 0) from obj_path
                                     where left(?, length(path)) = path and ? != path",
                                     $name, $name;
      $subpathmask[$id] = sql_fetch "select coalesce(sum(1 << id), 0) from obj_path
                                     where path like ?",
                                     "$name%";
      $parpath[$id] = $pathid{$name} if $name =~ s/[^\/]+\/$//;
   }

   for (values %obj_cache) {
      for (@$_) {
         $_ 
            and $_->{_paths} =
               sql_fetch "select paths from obj where gid = ? and paths & (1 << ?) <> 0",
                         $_->{_gid}, $_->{_path};
      }
   }
}

sub top_path {
   my $paths = $_[0];
   for (sort { (length $a) <=> (length $b) } keys %pathid) {
      return $pathid{$_} if and64 $paths, $pathmask[$pathid{$_}];
   }
   croak "top_path called with illegal paths mask";
}

our @sqlcol = (
   "string",
   "text",
   "int",
   "double",
);

sub any_data($) {
   "coalesce(" . (join ",", map "$_[0].d_$_", @sqlcol) . ")";
}

sub new_objectid() {
   sql_exec "lock tables obj_gidseq write";
   my $gid = sql_fetch "select seq from obj_gidseq";
   sql_exec "update obj_gidseq set seq = seq + 1";
   sql_exec "unlock tables";
   $gid;
}

sub insert_obj($$$) {
   sql_insertid sql_exec "insert into obj (id, gid, paths) values (?, ?, ?)",
                         $_[0], $_[1], $_[2];
}

sub newpath($) {
   unless (defined $pathid{$_[0]}) {
      my $path = "";
      sql_exec "lock tables obj_path write, obj write";
      for (split /\//, $_[0]) {
         my $parent = $path;
         $path .= "$_/";
         unless (sql_uexists "obj_path where path = ?", $path) {
            my $pathid = 0;
            $pathid++ while sql_exists "obj_path where id = ?", $pathid;
            $pathid < 64 or die "no space for new path $path, current limit is 64 paths\n";#d#

            sql_uexec "insert into obj_path (id, path) values (?, ?)", $pathid, $path;

            sql_exec "update obj set paths = paths | (1 << ?) where paths & (1 << ?) <> 0", $pathid, $pathid{$parent};
            $pathid{$path} = $pathid;
         }
      }
      PApp::Event::broadcast agni_update => [&UPDATE_PATHS];
      sql_exec "unlock tables";
   }
}

# return the pathid of the staging path corresponding to the given path
sub staging_path($) {
   defined $_[0] and defined $pathname[$_[0]] 
      or die "staging_path called without a pathid\n";
   (my $path = $pathname[$_[0]]) =~ s{/(staging/)?$}{/staging/};
   newpath $path unless exists $pathid{$path};
   defined $pathid{$path}
      or die "FATAL 101: unable to create staging path for $_[0] ($path)\n";
   $pathid{$path};
}

# the reverse to staging_path
sub commit_path($) {
   defined $_[0] and defined $pathname[$_[0]] 
      or die "staging_path called without a pathid\n";
   (my $path = $pathname[$_[0]]) =~ s{/staging/$}{/};
   newpath $path unless exists $pathid{$path};
   defined $pathid{$path}
      or die "FATAL 101: unable to create commit path for $_[0] ($path)\n";
   $pathid{$path};
}

sub staging_path_p($) {
   $pathname[$_[0]] =~ m{/staging/$};
}

#############################################################################

our $hold_updates;
our @held_updates;

sub hold_updates(&;@) {
   local $hold_updates = $hold_updates + 1;
   eval { &{+shift} };

   # ALWAYS broadcast updates, even if we are deeply nested
   if (@held_updates) {
      local $@;
      PApp::Event::broadcast agni_update => @held_updates;
      @held_updates = ();
   }

   die if $@;
}

sub update(@) {
   if ($hold_updates) {
      push @held_updates, @_;
   } else {
      PApp::Event::broadcast agni_update => @_;
   }
}

#############################################################################

sub gid($) {
   ref $_[0] ? $_[0]{_gid} : $_[0];
}

sub path_obj_by_gid($$) {
   $obj_cache{$_[1]}[$_[0]]
      or do {
         local $PApp::SQL::DBH = $DBH;
         update_class({ _path => $_[0], _gid => $_[1] })
      };
}

# like path_obj_by_gid, but is called by PApp::Storable
*storable_path_obj_by_gid = \&path_obj_by_gid;

# stolen & modified from Symbol::delete_package: doesn't remove the stash itself
sub empty_package ($) {
    my $pkg = shift;

    unless ($pkg =~ /^main::.*::$/) {
        $pkg = "main$pkg"       if      $pkg =~ /^::/;
        $pkg = "main::$pkg"     unless  $pkg =~ /^main::/;
        $pkg .= '::'            unless  $pkg =~ /::$/;
    }

    my($stem, $leaf) = $pkg =~ m/(.*::)(\w+::)$/;
    my $stem_symtab = *{$stem}{HASH};
    return unless defined $stem_symtab and exists $stem_symtab->{$leaf};

    # free all the symbols in the package

    my $leaf_symtab = *{$stem_symtab->{$leaf}}{HASH};
    foreach my $name (keys %$leaf_symtab) {
        undef *{$pkg . $name};
    }

    # delete the symbol table

    %$leaf_symtab = ();
}

our $bootstrap; # bootstrapping?
our %bootstrap; # contains postponed methods/objects

sub update_data {
   my $self = shift;

   # used to detect which types need to be removed
   my %prev = %{$self->{_type}};

   my $st = sql_exec \my($type, $name, $data),
                     "select m.type, name.d_string, " . (any_data "m") . "
                      from obj_attr m
   /* $self */                inner join obj tobj on (m.type = tobj.gid and tobj.paths & (1 << ?) <> 0)
                                 inner join obj_isa on (tobj.id = obj_isa.id and obj_isa.isa = $OID_DATA)
                                 inner join obj_attr name on (tobj.id = name.id and name.type = $OID_ATTR_NAME)
                      where m.id = ?",
                     $self->{_path}, $self->{_id};

   my %data;

   while ($st->fetch) {
      delete $prev{$name};

      if ($bootstrap) {
         $bootstrap{$self} = $self;
         # classes directly descending from string and having a name are considered simple strings
         if (sql_exists 
                "obj inner join obj_isa using (id)
                     inner join obj_attr name using (id)
                 where gid = ?
                   and isa = $OID_DATA_STRING and grade = 1
                   and name.type = $OID_ATTR_NAME
                   and paths & (1 << ?) <> 0",
                $type,
                $self->{_path}) {
            $self->{_cache}{$name} = $data;
         }

         # plant a bomb
         $self->{_type}{$name} = "non-bootstrap data access during bootstrap ($self->{_path}/$self->{_gid}\{$type=$name}";

         $self->{_postponed}{type}{$name} = $type;
         $self->{_postponed}{data}{$name} = $data;
      } else {
         my $tobj = path_obj_by_gid $self->{_path}, $type
            or die "unable to handle datatype $type\n";

         $self->{_type}{$name} = $tobj;

         eval {
            $data{$name} = $tobj->thaw($data, $self) if defined $data;
         };
         warn $@ if $@;
      }
   }

   delete @{$self->{_type}}{keys %prev};
   delete @{$self->{_cache}}{keys %prev};

   eval {
      $self->update(\%data);
   };
   warn $@ if $@;
}

# for bootstrapping and used in object::attr::named::method

# a single callback that preloads the object containing the real callback
my $agni_cb =
   PApp::Callback::register_callback
      \&agni_exec_cb,
      name => "agni_cb";

# load the object and call the corresponding callback
sub agni_exec_cb {
   my ($obj, $name) = splice @_, 0, 2;

   goto &{
      $obj->{_cb}{$name}
         or croak "cannot execute callback $obj->{_path}/$obj->{_gid}/$name for $_[0]{_path}/$_[0]{_gid}: callback doesn't exist";
   };
}

# substitute for PApp::Callback::register, used in perl/pxml2pcode
sub register_callback {
   my ($path, $gid, $cb, undef, $name) = @_;
   my $obj = path_obj_by_gid $path, $gid;

   $obj->{_cb}{$name} = $cb;

   $agni_cb->new(args => [$obj, $name]);
}

sub register_callback_info {
   my $self = shift;
   +{
      register_function => "Agni::register_callback $self->{_path}, $self->{_gid},",
      callback_preamble => "my \$self = shift;",
      argument_preamble => "\$self",
   }
}

# $NAMESPACE; # the current compilation namespace (NOT our because that's visible inside eval's!!!)

BEGIN {
   $objtag_start    = "\x{10f101}";
   $objtag_type_lo  = "\x{10f102}";
   $objtag_obj      = "\x{10f102}"; # inline object
   $objtag_obj_gid  = "\x{10f103}"; # inline object gid
   $objtag_obj_show = "\x{10f104}"; # inline show call on obj
   $objtag_type_hi  = "\x{10f1ed}";
   $objtag_end      = "\x{10f1fe}";
}

# compile code into the current namespace... also expands the special method gids

sub compile {
   #local $SIG{__DIE__}; local $SIG{__WARN__}; # speed, among others
   my $code = $_[0];

   $code =~ s{
      $objtag_start([$objtag_type_lo-$objtag_type_hi])([^$objtag_end]*)$objtag_end
   }{
      my ($type, $content) = ($1, $2);
      if ($type eq $objtag_obj) {
         "+(obj\"$content\")";
      } elsif ($type eq $objtag_obj_gid) {
         "'$content'";
      #} elsif ($type eq $objtag_obj_show) {
      #   "<\:(obj '$1')->show:\>";
      } else {
         warn "unknown method tag " . ((ord $type) - (ord $objtag_type_lo) + 2) . ", maybe you need a newer version of agni?\n";
         "";
      }
   }ogex;

   eval "package $NAMESPACE->{package}; $code";
}

sub compile_method_perl {
   my ($self, $name, $args, $code) = @_;

   my $args = join ",", '$self', split /[ \t,]+/, $args;

   my $class     = ref $self;
   my $isa_class = $self->{_isa} ? ref $self->{_isa} : agni::object::;

   $code =~ s/->SUPER::/"->$isa_class\::"/ge;
   $code =~ s/->SUPER(?!\w)/"->$isa_class\::$name$1"/ge;

   my $err = eval {
      compile "sub $class\::$name { my ($args) = \@_;\n"
            . "#line 1 \"$class\::$name\"\n"
            . "$code\n"
            . "}";
      $@;
   } || $@;

   if ($err) {
      *{"$class\::$name"} = sub {
         fancydie "can't call method $name because of compilation errors", $err, abridged => 1;
      };

      $last_compile_status = $err;
      warn $err;
   }
}

sub Agni::BootNamespace::eval {
   local $NAMESPACE = $_[0];
   compile $_[1];
}

sub Agni::BootNamespace::initialize {
   my $self = shift;
   # might be called multiple times
   $self->{_initialized} ||= do {
      # nop, for now
      1;
   };
}

sub get_namespace {
   my ($path, $gid) = @_;

   $ns_cache{$path, $gid} ||= do {
      my $namespace;

      # during bootstrap, everything is put into the agni namespace. oh yes!!
      if ($bootstrap) {
         return $agni_bootns[$path] if $agni_bootns[$path];
         $namespace = $agni_bootns[$path] = bless {
            _path  => $path,
            _gid   => $gid,
         }, Agni::BootNamespace::;
      } else {
         $namespace = path_obj_by_gid $path, $gid;
      }

      $namespace->{package} = "ns::$namespace->{_path}::$namespace->{_gid}";

      my $init_code = q~
         use Carp;
         use Convert::Scalar ':utf8';
         use List::Util qw(min max);

         use PApp;
         use PApp::Config ();
         use PApp::SQL;
         use PApp::HTML;
         use PApp::Exception;
         use PApp::Callback;
         use PApp::Env;
         use PApp::Util qw(dumpval);

         use PApp::Application ();

         use Agni qw(*env *app path_obj_by_gid gid);

         sub obj($) {
            ref $_[0] ? $_[0] : path_obj_by_gid PATH, $_[0];
         }

         # HACK BEGIN
         use PApp::XSLT;
         use PApp::ECMAScript;
         use PApp::XML qw(xml_quote);
         use PApp::UserObs;
         use PApp::PCode qw(pxml2pcode perl2pcode pcode2perl);

         #sub cins { (obj 787)->show($_[0]); }
         #sub oins { (obj 787)->print($_[0]); }

         #sub staticurl {
         #   (surl "static", &SURL_STYLE_STATIC) . "?obj=$_[0]";
         #}

         $papp_translator = PApp::I18n::open_translator(
                               "$PApp::i18ndir/mercury",
                            );
         sub __      ($){ PApp::I18n::Table::gettext(PApp::I18n::get_table($papp_translator, $PApp::langs), $_[0]) }
         sub gettext ($){ PApp::I18n::Table::gettext(PApp::I18n::get_table($papp_translator, $PApp::langs), $_[0]) }

         for my $src (qw(macro/editform macro/xpcse)) {
            my $imp = PApp::Application::find_import PApp::Util::find_file $src, ["papp"]
               or die "$src: not found";
            $imp->load_code;
            $imp->{root}{package}->import;
         }

         # HACK END
      ~;

      ${"$namespace->{package}::PATH"}      = $path;
      ${"$namespace->{package}::NAMESPACE"} = $namespace;

      $namespace->eval(qq~
            sub PATH() { $path }
            $init_code;
         ~);
      die if $@;

      $namespace->initialize;

      # don't cache the bootnamespace
      return $namespace if Agni::BootNamespace:: eq ref $namespace;
      $namespace;
  }
}

# the toplevel object, can't be edited etc.. but it exists ;)
our $toplevel_object = Agni::agnibless { }, agni::object::;

exists $toplevel_object->{_type} or die; # magic?

# a very complicated thing happens here: the initial loading of the
# objects necessary to work properly - during bootstrap, only string
# datatypes and perl methods are compiled, the rest is fixed later.
sub agni_bootstrap($) {
   my $path = $_[0];

   $path =~ /^\d+$/
      or fancydie "bootstrapping error", "tried to bootstrap path '$path', which is not a valid path";

   local $bootstrap = 1;

   # Load the absolute minimum set of objects that allows
   # loading of arbitrary other objects. These objects
   # will only load partially(!)
   for my $gid ($OID_OBJECT, $OID_NAMESPACE_AGNI) {
      path_obj_by_gid $path, $gid;
      $BOOTSTRAP_LEVEL{$gid} ||= $bootstrap;
   }

   ####################

   # the namespace must be loaded now... or is it not?
   my $namespace = $obj_cache{$OID_NAMESPACE_AGNI}[$path]
      or die "FATAL 20: boot namespace for path $path not loaded after bootstrapping";

   $ns_cache{$namespace->{_path}, $namespace->{_gid}} = $namespace;
   delete $agni_bootns[$path]
      or die "FATAL 21: no bootnamespace for path $path after bootstrapping";

   $namespace->{package} = "ns::$namespace->{_path}::$namespace->{_gid}";
   $namespace->initialize;

   ####################

   # fix types of bootstrap objects (still in bootstrap mode, so iterate)
   while (%bootstrap) {
      $bootstrap++;
      my @bs = values %bootstrap; %bootstrap = ();
      for my $self (@bs) {
         my $postponed = delete $self->{_postponed};

         $self->{_path} == $path
            or die "FATAL 23: path mismatch, path $path needs object $self->{_path}/$self->{_gid}??";

         $BOOTSTRAP_LEVEL{$self->{_gid}} ||= $bootstrap;

         # fixing datatypes
         while (my ($name, $type) = each %{$postponed->{type}}) {
            my $tobj = path_obj_by_gid $self->{_path}, $type
               or die "FATAL 24: unable to handle bootstrap datatype $type for object $self->{_path}/$self->{_gid}\n";
            $self->{_type}{$name} = $tobj;
            eval {
               $self->update($name => $tobj->thaw($postponed->{data}{$name}, $self));
            };
            warn $@ if $@;
         }

         # compile remaining methods
         local $PApp::PCode::register_callback = register_callback_info($self);
         while (my ($type, $data) = each %{$postponed->{method}}) {
            local $NAMESPACE = get_namespace $self->{_path}, $OID_NAMESPACE_AGNI; # loads bootnamespace
            eval {
               (path_obj_by_gid $self->{_path}, $type)->compile($self, $data);
            };
            warn $@ if $@;
         }

      }
   }
}

sub update_class($) {
   my $self = $_[0];

   rmagical_off $self;

   # sanity check since mysql compares 45 and '45"' as equal..
   "$self->{_path}$self->{_gid}" =~ /^[0-9]+$/ or return undef;

   # is the root object available or do we need to bootstrap?
   unless ($obj_cache{1}[$self->{_path}] or $bootstrap) {
      isobject $self
         and die "FATAL 3: bootstrapping caused by already loaded object";
      agni_bootstrap $self->{_path};

      # can't reuse $self (could already be loaded!), so just return sth. else
      return path_obj_by_gid $self->{_path}, $self->{_gid};
   }

   sql_fetch \my($id, $paths, $isa, $namespace),
             "select obj.id, paths, isa, namespace.d_int
              from obj
                 left join obj_isa on (obj.id = obj_isa.id and grade = 1)
                 left join obj_attr namespace on (obj.id = namespace.id and namespace.type = $OID_META_NAMESPACE)
              where obj.gid = ? and paths & (1 << ?) <> 0",
             "$self->{_gid}", $self->{_path};

   $id or return undef;

   # to avoid endless recursion, set the object before loading the isa object
   # (not a problem under normal circumstances)
   $obj_cache{$self->{_gid}}[$self->{_path}] = $self;

   $self->{_id}        = $id;
   $self->{_paths}     = $paths;
   $self->{_namespace} = $namespace;
   $self->{_isa}       = $isa ? path_obj_by_gid($self->{_path}, $isa) : $toplevel_object
      or die "ISA class ($isa) of object $self->{_path}/$self->{_gid} doesn't exist or couldn't be loaded";

   my $isa_class = ref $self->{_isa};
   my $old_class = ref $self eq "HASH" ? undef : ref $self;

   my $st = $namespace && sql_exec \my($type, $data),
                     "select m.type, m.d_text
                      from obj_attr m
   /* $self */                inner join obj tobj on (m.type = tobj.gid and tobj.paths & (1 << ?) <> 0)
                              inner join obj_isa on (tobj.id = obj_isa.id and obj_isa.isa = $OID_METHOD)
                      where m.id = ?",
                     $self->{_path},
                     $self->{_id};

   if ($st and $st->fetch) {
      local $NAMESPACE = get_namespace $self->{_path}, $self->{_namespace};

      my $method_type;

      !$bootstrap or $self->{_namespace} == $OID_NAMESPACE_AGNI
         or die "FATAL 31: bootstrapping object $self->{_path}/$self->{_gid} needs non-agni namespace $self->{_namespace}";

      local $PApp::PCode::register_callback = register_callback_info($self);

      $class = "agni::$self->{_path}::$self->{_gid}";

      @{"$class\::ISA"} = $isa_class;

      agnibless $self, $class;

      do {
         # preset the _method_type hash
         $method_type->{$name} = $type;

         if ($bootstrap) {
            $bootstrap{$self} = $self;

            # classes directly descending from method::perl and having a name are considered simple perl methods
            sql_fetch \my($name, $args, $super_class),
                "select name.d_string, args.d_string, obj_isa.isa
                 from obj
                     inner join obj_isa using (id)
                     inner join obj_attr name using (id)
                     inner join obj_attr args using (id)
                 where gid = ?
                   and grade = 1
                   and name.type = $OID_ATTR_NAME
                   and args.type = $OID_METHOD_ARGS
                   and paths & (1 << ?) <> 0",
                $type,
                $self->{_path};

            if ($super_class == $OID_METHOD_PERL) {
               compile_method_perl $self, $name, $args, pcode2perl perl2pcode $data;
            } else {
               # non-perl-method, store for later use
 
               # plant a bomb
               *{"$class\::$name"} = sub { die "non-bootstrap method $class->$name ($args) called during bootstrap" };

               $self->{_postponed}{method}{$type} = $data;
            }
              
         } else {
            eval {
               (path_obj_by_gid $self->{_path}, $type)->compile($self, $data);
            };
            warn $@ if $@;
         }

      } while $st->fetch;

      my $old_methods = delete $self->{_method_type};
      $self->{_method_type} = $method_type;

      # clean up package
   } else {
      if ($old_class and $old_class ne $isa_class) {
         empty_package $old_class;
      }
      agnibless $self, $isa_class;
   }

   update_data $self;

   # may need to fix up the ISA of objects on ISA changes
   #d# ALSO NEED TO FIX @ISA(!!!) #d# TODO #FIXME
   if ($old_class and $old_class ne $isa_class) {
      warn "noclass => class upgrades not yet fully implemented!!!\n";#d#
      my $isa = { $self->{_gid} => 1 };
      do {
         my $next;
         for (values %obj_cache) {
            if ($old_class eq ref $_->[$self->{_path}]) {
               my $o = $_->[$self->{_path}];
               if ($isa->{$o->{_isa}{_gid}}) {
                  agnibless $o, ref $self if ref $o eq $old_class;
                  $next->{$o->{_gid}}++;
               }
            }
         }
      } while %{$isa = $next};
   }

   $self;
}

#############################################################################

# make sure the object described by $paths|$gid|$id is copied into the
# target layer. returns the new id on copy or undef otherwise.
# another way to view this operation is that the object is split
# at the path $target and the id of the copy is returned (if one was created)

sub split_obj {
   my ($paths, $gid, $id, $target) = @_;

   sql_exec "lock tables obj write, obj_attr write, obj_isa write";
   my $newid = eval {
      local $SIG{__DIE__};
      insert_obj undef, $gid, and64 $paths, $subpathmask[$target];
   };
   if ($newid) {
      sql_exec "update obj set paths = paths &~ ? where id = ?", $subpathmask[$target], $id;

      my $st = sql_exec \my($isa, $grade), "select isa, grade from obj_isa where id = ?", $id;
      sql_exec "insert into obj_isa (id, isa, grade) values (?, ?, ?)", $newid, $isa, $grade
         while $st->fetch;

      @Agni::sqlcol == 4 or die "FATAL: \@Agni::sqlcol has been changed\n";

      my $st = sql_exec \my($type, $d_string, $d_text, $d_int, $d_double),
                        "select type, d_string, d_text, d_int, d_double from obj_attr where id = ?",
                        $id;
      sql_exec "insert into obj_attr (id, type, d_string, d_text, d_int, d_double) values (?, ?, ?, ?, ?, ?)",
               $newid, $type, $d_string, $d_text, $d_int, $d_double
         while $st->fetch;

      sql_exec "unlock tables";

      Agni::update [UPDATE_PATHID, $paths, $gid];
   } else {
      sql_exec "unlock tables";
   }
   $newid;
}

sub agni::object::copy_to_path {
   my ($self, $target) = @_;

   defined $target or $target = $self->{_path};

   if (and64 $self->{_paths}, $pathmask[$target]) {
      # object is from the target path
      if (and64 $self->{_paths}, $parpathmask[$target]) {
         split_obj $self->{_paths}, $self->{_gid}, $self->{_id}, $target
            || sql_fetch "select id from obj where gid = ? and paths & (1 << ?) <> 0", $self->{_gid}, $target;
      } else {
         $self->{_id};
      }
   } else {
      # object is outside the target path, fetch the id of the correct object
      sql_fetch "select id from obj where gid = ? and paths & (1 << ?) <> 0", $self->{_gid}, $target;
   }
}

sub agni::object::store_data {
   my $self = shift;
   my @names = @_;

   return unless $self->{_id};

   #sql_exec "lock tables obj_attr write, obj write";
   eval {
      local $SIG{__DIE__};

      @names or @names = keys %{$self->{_type}};

      for my $name (@names) {
         $tobj = $self->{_type}{$name}
            or die "tried to call store_data with non-existent data member '$name'";
         $tobj->store($self, $tobj->freeze($self->{$name}));
      }
   };
   #sql_exec "unlock tables";
   die if $@;

}

sub agni::object::name     { "\x{4e0a}" }
sub agni::object::fullname { "\x{4e0a}" }

sub agni::object::isa_obj {
   $_[0]{_isa};
}

sub update_isa {
   my ($self) = @_;
   my $grade = 0;
   my $id = $self->{_id};

   sql_exec "lock tables obj_isa write";
   do {
      sql_exec "replace into obj_isa (id, isa, grade) values (?, ?, ?)", $id, $self->{_gid}, $grade++;
      $self = $self->{_isa};
   } while $self->{_gid};
   sql_exec "delete from obj_isa where id = ? and grade >= ?", $id, $grade;
   sql_exec "unlock tables";
}

sub agni::object::obj {
   my ($self, $gid_or_obj) = @_;

   die "self->obj is obsolete, use 'obj gid' instead";
}

=item commit_objs [$gid, $src_path, $dst_path], ...

Commit (copy) objects from one path to another. If C<$dst_path> is
undefined or missing, deletes the object.

Currently, C<$src_path> must be the "topmost" path of one object instace,
undefined behaviour will result if the instance exists in a path higher
than C<$src_path>.

It returns a html fragment describing it's operations.

 # delete the root object (gid 1) from the staging path
 Agni::commit_objs [1, $Agni::pathid{"root/staging/"}, undef];

=cut

sub commit_objs {
   my $args = \@_;
   PApp::capture {
      my @event;
      sql_exec "lock tables obj write, obj_attr write, obj_isa write,
                            obj_attr name1 read, obj_attr name2 read";

      :><p><:
      eval {
         for (@$args) {
            my ($obj_gid, $src, $dst) = @$_;
            my ($obj_paths, $obj_id);

            :>gid <?$obj_gid:>...<:

            if (my $obj = $obj_cache{$obj_gid}[$src]) {
               :><b><?escape_html $obj->fullname:></b>...<:
               ($obj_paths, $obj_id) = ($obj->{_paths}, $obj->{_id});
            } else {
               ($obj_paths, $obj_id, my $name)
                  = sql_fetch "select paths, obj.id, coalesce(name1.d_string, concat('#', name2.d_string), concat('#', gid))
                               from obj
                                  left join obj_attr name1 on (obj.id = name1.id and name1.type = $OID_META_NAME)
                                  left join obj_attr name2 on (obj.id = name2.id and name2.type = $OID_ATTR_NAME)
                               where paths & (1 << ?) <> 0 and gid = ?",
                              $src, $obj_gid;
               :><b><?escape_html Convert::Scalar::utf8_on $name:></b>...<:
            }

            and64 $parpathmask[$src], $obj_paths
               and croak "commit_objs: src_path $src not the highest path of object $obj_gid";

            # first unlink the object from the src layer.
            sql_exec "update obj set paths = paths | ? where gid = ? and paths & (1 << ?) <> 0",
                     $obj_paths, $obj_gid, $parpath[$src];

            if (defined $dst) {
               my $dst_paths;

               # then find the object that currently is visible in the target layer
               sql_fetch \my($id, $paths),
                         "select id, paths from obj where gid = ? and paths & (1 << ?) <> 0",
                         $obj_gid, $dst;

               # can't happen anymore?
               $id != $obj_id or croak "FATAL, pls report! commit_objs: src_path $src_path not the highest path of object $obj_gid";
                         
               if ($id) {
                  # remove it from the target path
                  if (andnot64 $paths, $subpathmask[$dst]) {
                     :><?"splitting $id...":><:
                     sql_exec "update obj set paths = paths &~ ? where id = ?",
                               $subpathmask[$dst], $id;
                  } else {
                     :><?"replacing $id...":><:
                     sql_exec "delete from obj      where id = ?", $id;
                     sql_exec "delete from obj_isa  where id = ?", $id;
                     sql_exec "delete from obj_attr where id = ?", $id;
                  }
                  push @event, [UPDATE_PATHID, $paths, $obj_gid];

                  # move the commit object into the target path
                  $dst_paths = and64 $paths, $subpathmask[$dst];
               } else {
                  :><?"created $id...":><:
                  # calculcate all mask bits sans the obj_paths, use sum
                  $dst_paths = sql_fetch "select sum(paths) from obj where id != ? and gid = ?", $obj_id, $obj_gid;

                  # now move the object into the target path
                  $dst_paths = andnot64 $subpathmask[$dst], $dst_paths;
               }

               sql_exec "update obj set paths = ? where id = ?", $dst_paths, $obj_id;
               push @event, [UPDATE_CLASS, (or64 $dst_paths, $obj_paths), $obj_gid];
            } else {
               :><?"removing $obj_id...":><:

               sql_exec "delete from obj      where id = ?", $obj_id;
               sql_exec "delete from obj_isa  where id = ?", $obj_id;
               sql_exec "delete from obj_attr where id = ?", $obj_id;

               push @event, [UPDATE_CLASS, $obj_paths, $obj_gid];
            }
            :><br /><:
         }
      }
      :></p><:

      if ($@) {
         :><error><?escape_html $@:></error><:
      }

      sql_exec "unlock tables";
      PApp::Event::broadcast agni_update => @event;
   };
}

sub import_objs {
   my ($objs, $pathid, $delete_layer) = @_;

   defined $pathid or croak "import_objs: undefined pathid\n";

   my $pathmask = $pathmask[$pathid];
   my $submask  = $subpathmask[$pathid];

   my %type_cache;
   my %obj;

   $obj{1} = { }; # object one doesn't have an isa

   for (@$objs) {
      $_->{gid} or croak "import_objs: object without gid";

      $type_cache{$_->{gid}} = $_->{attr}{$OID_ATTR_SQLCOL};

      $obj{$_->{gid}} = $_;
   }

   sql_exec "lock tables obj write, obj_attr write, obj_gidseq write, obj_isa write";

   eval {
      for (@$objs) {
         my $gid = $_->{gid};

         # generate isa array first
         my @isa;
         do {
            unshift @isa, $gid;
            $obj{$gid} ||= do {
               my $id = sql_fetch "select id from obj where gid = ? and paths & (1 << ?) <> 0", $gid, $pathid;
               my $isa = sql_fetch "select isa from obj_isa where grade = 1 and id = ?", $id;
               $isa or croak "import_objs: can't resolve isa of object $gid";
               { isa => $isa };
            };
            $gid = $obj{$gid}{isa};
         } while $gid;

         $_->{isa_array} = \@isa;

         # check types next
         while (my ($type, $value) = each %{$_->{attr}}) {
            exists $type_cache{$type} or $type_cache{$type} = do {
               my $id = sql_fetch "select id from obj where gid = ? and paths & (1 << ?) <> 0", $type, $pathid
                  or croak "import_objs: can't resolve type $type (used in object $_->{gid})";
               sql_ufetch "select d_string from obj_attr where id = ? and type = ?", $id, $OID_ATTR_SQLCOL;
            };
            defined $type_cache{$type} or !defined $value;
         }
      }

      my @event;

      if ($delete_layer) {
         my $st = sql_exec \my($id),
                           "select id from obj where paths & ? <> 0 and paths & ? = 0",
                           $pathmask, $parpathmask[$pathid];
         while ($st->fetch) {
            sql_exec "delete from obj_attr where id = ? and type = $Agni::OID_ROOTSET", $id;
         }
      }

      for my $o (@$objs) {
         sql_exec "update obj set paths = paths & ~? where gid = ? and paths & ~? <> 0", $submask, $o->{gid}, $submask;

         my $st = sql_exec \my($id), "select id from obj where gid = ? and paths & ? <> 0", $o->{gid}, $pathmask;
         while ($st->fetch) {
            sql_exec "delete from obj      where id = ?", $id;
            sql_exec "delete from obj_isa  where id = ?", $id;
            sql_exec "delete from obj_attr where id = ?", $id;
         }

         my $obj_mask = sql_fetch "select ? - coalesce(sum(paths),0) from obj where gid = ? and paths & ~? = 0",
                                  $submask, $o->{gid}, $submask;

         my $id = insert_obj undef, $o->{gid}, $obj_mask;

         #print "importing $o->{gid} (@{$o->{isa_array}}) ($pathmask,$submask,objmask $obj_mask) as $id\n";

         while (my ($type, $data) = each %{$o->{attr}}) {
            if (defined $type_cache{$type}) {
               sql_exec "insert into obj_attr (id, type, d_$type_cache{$type}) values (?, ?, ?)",
                        $id, $type, $data;
            } else {
               sql_exec "insert into obj_attr (id, type) values (?, ?)",
                        $id, $type;
            }
         }

         my $isa = $o->{isa_array};

         # slow but faster :(, maybe due to lock tables?
         for (my $grade = @$isa; $grade--; ) {
            sql_exec "insert into obj_isa (id, isa, grade) values (?, ?, ?)",
                     $id, $isa->[$grade], @$isa - 1 - $grade;
         }

         push @event, [Agni::UPDATE_CLASS, $obj_mask, $o->{gid}];
      }

      Agni::update @event;
   };

   sql_exec "unlock tables";

   die if $@;
}

sub find_dead_objects {
   my %dead; # all dead gids
   my %isai; # all ids implementing the attr_container interface
   my %isac; # all objects id's that are attr::container's

   my ($seed, $next); # set of seed (newly alive) object ids, objects alive in next round

   my $lock_tables = "lock tables obj read, obj iobj read, obj_isa isa read, obj_attr attr read, obj type read";

   sql_exec $lock_tables;

   eval {
      # first mark all objects as dead. the gc will have to find the live ones
      my $st = sql_exec \my($id), "select id from obj";
      $dead{$id} = 1 while $st->fetch;

      # find all types implementing $OID_IFACE_CONTAINER
      my $st = sql_exec \my($id),
                        "select iobj.id
                         from obj
                            inner join obj_attr attr on (attr.id = obj.id and attr.type = $OID_IFACE_CONTAINER)
                            inner join obj_isa isa on (isa.isa = obj.gid)
                            inner join obj iobj on (isa.id = iobj.id and iobj.paths & obj.paths <> 0)";
      $isai{$id} = 1 while $st->fetch;

      # find all types that are attr::container's and special-case them (fast)

      my $st = sql_exec \my($id),
                        "select id from obj_isa isa where isa = $OID_ATTR_CONTAINER";
      $isac{$id} = delete $isai{$id} or die "isac $id is not isai!" while $st->fetch;

      grep !defined $_, values %isac and croak "isac not a subset of isai, check type tree!";

      # the root-set of alive objects (currently only the rootset)
      push @$seed, sql_fetchall "select id from obj where gid = $OID_ROOTSET";

      while (@$seed) {
         $next = [];

         for my $id (@$seed) {
            # check wether this object is a container type
            # (this is an important optimization)
            if ($isac{$id}) {
               push @$next, grep delete $dead{$_},
                  sql_fetchall "select distinct obj.id
                                from obj
                                   inner join obj_attr attr using (id)
                                   inner join obj type on (type.gid = attr.type)
                                where type.id = ? and obj.paths & type.paths <> 0",
                               $id;
            }
         }

         my $in = join ",", @$seed;

         # mark the isa objects as alive
         push @$next, grep delete $dead{$_},
            sql_fetchall "select distinct iobj.id
                          from obj iobj
                             inner join obj_isa isa on (isa.isa = iobj.gid and grade = 1)
                             inner join obj on (obj.id = isa.id)
                          where obj.id in ($in) and obj.paths & iobj.paths <> 0";
            
         # now fetch all attrs of the objects, mark them alive and resolve forward references
         my $st = sql_exec \my($id, $tgid, $tid, $paths),
                           "select obj.id, attr.type, type.id, type.paths
                            from obj
                               inner join obj_attr attr on (attr.id = obj.id)
                               inner join obj type on (attr.type = type.gid)
                            where obj.id in ($in)";

         sql_exec "unlock tables";

         while ($st->fetch) {
            # mark the types alive
            push @$next, $tid if !$isac{$tid} && delete $dead{$tid};

            # forward-resolve types implementing the obj_container interface
            if ($isai{$tid}) {

               # do it for every single path. this is not very efficient, but very correct
               for my $path (values %pathid) {
                  next unless and64 $paths, $pathmask[$path];

                  my $tobj = path_obj_by_gid $path, $tgid
                     or croak "FATAL: garbage_collect cannot load type object ({$paths}/$tgid)";

                  my $data =
                     sql_fetch "select d_$tobj->{sqlcol}
                                from obj_attr attr where id = ? and type = ?",
                               $id, $tgid;

                  my $gids = $tobj->attr_enum_gid($data);

                  if (@$gids) {
                     my $st = sql_exec \my($id), "select id from obj
                                                  where gid in (".(join ",", @$gids).") and paths & (1 << ?) <> 0",
                                                 $path;
                     while ($st->fetch) {
                        push @$next, $id if delete $dead{$id};
                     }
                  }
               }
            }
         }

         sql_exec $lock_tables;

         $seed = $next;
      }

   };

   sql_exec "unlock tables";
   die if $@;

   [keys %dead];
}

sub mass_delete_objects {
   my ($ids) = @_;

   sql_exec "lock tables obj write, obj_isa write, obj_attr write";

   # adjust paths... should instead call an object method instead
   for my $id (@$ids) {
      my ($gid, $paths) = sql_fetch "select gid, paths from obj where id = ?", $id;
      sql_exec "update obj set paths = paths | ? where gid = ? and paths & ? <> 0",
               $paths, $gid, $parpathmask[top_path($paths)];
   }

   my $in = join ",", @$ids;

   sql_exec "delete from obj      where id in ($in)";
   sql_exec "delete from obj_isa  where id in ($in)";
   sql_exec "delete from obj_attr where id in ($in)";
   sql_exec "unlock tables";
}

#############################################################################

local $PApp::SQL::Database = $Database;
local $PApp::SQL::DBH      = $DBH;

init_paths;

sub flush_all_objects {
   for (values %obj_cache) {
      for (grep $_, @$_) {
         if (1 >= Convert::Scalar::refcnt_rv $_ and !$BOOTSTRAP_LEVEL{$_->{_gid}}) {
            $_ = undef;
         } else {
            update_class $_;
         }
      }
   }
}

PApp::Event::on agni_update => sub {
   shift;

   my %todo;

   # this bundling does slightly more than necessary, i.e. if one object
   # gets a PATHID update in one path and an CLASS update in another
   # it will class-update all
   for (@_) {
      my ($type, $paths, $gid) = @$_;

      if ($type == UPDATE_PATHS) {
         init_paths;
         for (values %obj_cache) {
            for (@$_) {
               $_
                  and $_->{_paths} =
                     sql_fetch "select paths from obj where gid = ? and paths & (1 << ?) <> 0",
                               $_->{_gid}, $_->{_path};
            }
         }
      } elsif ($type == UPDATE_ALL) {
         flush_all_objects;
      }

      $todo{$gid}[0] |= $type;
      $todo{$gid}[1] = or64 $todo{$gid}[1], $paths;
   }

   while (my ($gid, $v) = each %todo) {
      my ($type, $paths) = @$v;
      if ($type & UPDATE_CLASS) {
         for (grep $_, @{$obj_cache{$gid}}) {
            my $refcnt = Convert::Scalar::refcnt_rv $_; # we use a temporary value since ->{_paths} incs the refcnt
            if (and64 $paths, $_->{_paths}) {
               if (1 >= $refcnt and !$BOOTSTRAP_LEVEL{$gid}) {
                  $_ = undef;
               } else {
                  update_class $_;
               }
            }
         }
      } else {
         if ($type & UPDATE_PATHID) {
            for (@{$obj_cache{$gid}}) {
               if ($_ and and64 $paths, $_->{_paths}) {
                  ($_->{_paths}, $_->{_id}) =
                     sql_fetch "select paths, id from obj
                                where paths & (1 << ?) <> 0 and gid = ?",
                                $_->{_path}, $_->{_gid};
               }
            }
         }

         if ($type & UPDATE_DATA) {
            $_ and and64 $paths, $_->{_paths} and update_data $_ for @{$obj_cache{$gid}};
         }
      }
   }
};

=head2 UTILITY FUNCTIONS

=over 4

=item path_gid2name $path, $gid

Tries to return the name of the object, or some descriptive string, in
case the object lacks a name. Does not load the object into memory.

=cut

sub path_gid2name($$) {
   my ($path, $gid) = @_;
   if (my $obj = $obj_cache[$path]{$gid}) {
      return $obj->name;
   } else {
      sql_fetch \my($parcel, $namespace, $name, $name2, $isa),
                "select p.d_int, s.d_int, n.d_string, o.d_string, i.isa
                 from obj
                    left join obj_attr p on obj.id = p.id and p.type = $OID_META_PARCEL
                    left join obj_attr s on obj.id = s.id and s.type = $OID_META_NAMESPACE
                    left join obj_attr n on obj.id = n.id and n.type = $OID_META_NAME
                    left join obj_attr o on obj.id = o.id and o.type = $OID_ATTR_NAME
                    left join obj_isa i on obj.id = i.id and i.grade = 1
                 where obj.paths & (1 << ?) <> 0 and obj.gid = ?",
                $path, $gid;
      $namespace &&= (path_obj_by_gid $path, $namespace)->name . "/";
      $parcel and $namespace = "(" . (path_obj_by_gid $path, $parcel)->name . ")$namespace";
      $name2 and $name ||= "#$name2";
      if ($name) {
         return $namespace . Convert::Scalar::utf8_on $name;
      } elsif ($isa) {
         $namespace . (path_obj_by_gid $path, $isa)->name . "(#$gid)";
      } else {
         "$namespace#$gid";
      }
   }
}

=back

=cut

1;

=head1 SEE ALSO

The C<bin/agni> commandline tool, the agni online documentation.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut


