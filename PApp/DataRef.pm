=head1 NAME

PApp::DataRef - reference data stored in scalars, databases...

=head1 SYNOPSIS

 use PApp::DataRef;

=head1 DESCRIPTION

You often want to store return values from forms (e.g. L<macro/editform>)
or other "action at a distance" events in your state variable or in a
database (e.g. after updates). The L<DBIx::Recordset|DBIx::Recordset>
provides similar functionality.

C<PApp::DataRef> provides the means to create "handles" that can act like
normal perl references. When accessed they fetch/store data from the
underlying storage.

All of the generated references and handles can be serialized.

=over 4

=cut

package PApp::DataRef;

use Convert::Scalar ();

$VERSION = 0.122;

=item $hd = new PApp::DataRef 'DB_row', table => $table, where => [key, value], ...;

Create a new handle to a table in a SQL database. C<table> is the name
(view) of the database table. The handle will act like a reference to a
hash. Accessing the hash returns references to tied scalars that can be
read or set (or serialized).

 my $hd = new PApp::DataRef 'DB_row', table => env, where => [name => 'TT_LIBDIR'];
 print ${ $hd->{value} }, "\n";
 ${ $hd->{value} } = "new libdir value";

The default database handle (C<$PApp::SQL::DBH>) is used for all sql
accesses. (Future versions might be more intelligent).

As a special case, if the C<value> part of the C<where> agruments is
undef, it will be replaced by some valid (newly created) id on the first
STORE operation. This currently only works for mysql ;*)

Parameters

   table         the database table to use
   where         a array-ref with the primary key fieldname and primary key
                 value

   autocommit    if set to one (default) automatically store the contents
                 when necessary or when the object gets destroyed
   delay         if set, do not write the table for each update
                 (delay implies caching of stored values(!))
   cache         if set, cache values that were read
   preload       if set to a true value, preloads the values from the table on
                 object creation. If set to an array reference, only the mentioned
                 fields are being cached.
   database      the PApp::SQL::Database object to use. If not specified,
                 the default database at the time of the new call is used.
   utf8          can be set to a boolean, an arrayref or hashref that decides
                 wether to force the utf8 bit on or off for the selected fields.
                 [THIS IS AN EXPERIMENTAL EXTENSION]

=item $hd = new PApp::DataRef 'File', path => ..., perm => ...;

Create a new handle that fetches and stores a file. [NYI]

=item $hd = new PApp::DataRef 'Scalar', fetch => ..., ...;

Create a scalar reference that calls your callbacks when accessed. Valid arguments are:

  fetch => coderef
    a coderef which is to be called for every read access
  value => constant
    as an alternative to fetch, always return a constant on read accesses
  store => coderef
    a coderef which is to be called with the new value for every write access

Either C<fetch> or C<value> must be present. If C<store> is missing,
stored values get thrown away.

=cut

sub new {
   my $class = shift;

   my $type = "PApp::DataRef::".shift;

   unless (defined &{"${type}::new"}) {
      eval "use $type"; die if $@;
   }

   $type->new(@_);
}

package PApp::DataRef::Base;

use Carp ();

sub TIESCALAR {
   my $class = shift;
   bless shift, $class;
}

sub new   { Carp::croak "new() not implemented for ".ref $_[0] }
sub FETCH { Carp::croak "FETCH not implemented for ".ref $_[0] }
sub STORE { Carp::croak "STORE not implemented for ".ref $_[0] }

sub DESTROY { }

package PApp::DataRef::Scalar;

@ISA = PApp::DataRef::Base::;

sub new {
   my $class = shift;

   my $handle;
   tie $handle, $class, @_;
   \$handle;
}

sub TIESCALAR {
   my $class = shift;
   bless { @_ }, $class;
}

sub FETCH {
   my $self = $_[0];
   if ($self->{fetch}) {
      return $self->{fetch}();
   } elsif (exists $self->{value}) {
      return $self->{value};
   } else {
      # might become a warning or fatal error
      return undef;
   }
}

sub STORE {
   my $self = $_[0];
   if ($self->{store}) {
      $self->{store}($_[1]);
   } else {
      # might become a warning or fatal error
      ();
   }
}

package PApp::DataRef::DB_row;

use PApp::SQL;

use Carp ();

sub new {
   my $class = shift;
   my %handle;

   tie %handle, $class, @_;
   bless \%handle, PApp::DataRef::DB_row::Proxy;
}

sub dbh {
   $_[0]{database}->dbh;
}

sub TIEHASH {
   my $class = shift;
   my $self = bless { @_ }, $class;

   exists $self->{autocommit} or $self->{autocommit} = 1;
   exists $self->{database}   or $self->{database}   = $PApp::SQL::Database
      or die "no database given and no default database found";

   exists $self->{table} or Carp::croak("mandatory parameter table missing");
   exists $self->{where} or Carp::croak("mandatory parameter where missing");

   if (exists $self->{utf8}) {
      if (ref $self->{utf8} eq "ARRAY") {
         $self->{utf8}{$_} = 1 for @{$self->{utf8}};
      }
   }

   if (my $preload = delete $self->{preload} and $self->{where}[1]) {
      # try to preload, enable caching
      $preload = ref $preload ? join ",", @$preload : "*";
      my $st = sql_exec $self->{database}->dbh,
                        "select $preload from $self->{table} where $self->{where}[0] = ?",
                        $self->{where}[1];
      my $hash = $st->fetchrow_hashref;
      while (my ($field, $value) = each %$hash) {
         Convert::Scalar::utf8_on $value if $self->{utf8} && (!ref $self->{utf8} || $self->{utf8}{$field});
         $self->{_cache}{$field} = $value;
      }
      $st->finish;
   }

   $self;
}

=item $hd->{fieldname} or $hd->{[fieldname, extra-args]}

Return a lvalue to the given field of the row. The optional arguments
C<fetch> and C<store> can be given code-references that are called at
every fetch and store, and should return their first argument (possibly
modified), e.g. to fetch and store a crypt'ed password field:

  my $pass_fetch = create_callback { "" };
  my $pass_store = create_callback { crypt $_[1], <salt> };

  $hd->{["password", fetch => $pass_fetch, store => $pass_store]};

Additional named parameters are:

  fetch => $fetch_cb,
  sore => $store_cb,
     
     Functions that should be called with the fetched/to-be-stored value
     as second argument that should be returned, probably after some
     transformations have been used on it. This can be used to convert
     sql-sets or password fields from/to their internal database format.

     If the store function returns nothing (an empty 'list', as it is
     called in lsit context), the update is being skipped.

     L<PApp::Callback> for a way to create serializable code references.

     PApp::DataRef::DB_row predefines some filter types (these functions
     return four elements, i.e. fetch => xxx, store => xxx, so that you
     cna just cut & paste them).

        PApp::DataRef::DB_row::filter_sql_set
                  converts strings of the form a,b,c into array-refs and
                  vice versa.

        PApp::DataRef::DB_row::filter_password
                  returns the empty string and crypt's the value if nonempty.

=cut

use PApp::Callback;

my $sql_set_fetch = create_callback {
   [split /,/, $_[1]];
} name => "papp_dataref_set_fetch";

my $sql_set_store = create_callback {
   join ",", @{$_[1]};
} name => "papp_dataref_set_store";

my $sql_pass_fetch = create_callback {
   "";
} name => "papp_dataref_pass_fetch";

my $sql_pass_store = create_callback {
   $_[1] ne "" ? crypt $_[1], join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64] : ();
} name => "papp_dataref_pass_store";

sub filter_sql_set  (){ ( fetch => $sql_set_fetch,  store => $sql_set_store  ) }
sub filter_password (){ ( fetch => $sql_pass_fetch, store => $sql_pass_store ) }

sub _sequence {
   my $self = shift;

   unless ($self->{where}[1]) {
      # create a new ID
      $self->{where}[1] = sql_insertid
         sql_exec $self->dbh,
            "insert into $self->{table} values ()";
   }
}

sub FETCH {
   my $self = shift; my ($field, %args) = ref $_[0] ? @{+shift} : shift;
   my $value;

   if (exists $self->{_cache}{$field}) {
      $value = $self->{_cache}{$field};
   } else {
      if ($self->{where}[1]) {
         $value = sql_fetch $self->dbh, "select $field from $self->{table} where $self->{where}[0] = ?",  $self->{where}[1];
         Convert::Scalar::utf8_on $value if $self->{utf8} && (!ref $self->{utf8} || $self->{utf8}{$field});
         $self->{_cache}{$field} = $value if $self->{cache};
      } else {
         $value = ();
      }
   }

   ref $args{fetch} ? $args{fetch}->($self, $value) : $value;
}

sub STORE {
   my $self = shift; my ($field, %args) = ref $_[0] ? @{+shift} : shift;
   my @value = ref $args{store} ? $args{store}->($self, shift) : shift;
   return unless @value;

   Convert::Scalar::utf8_upgrade $value[0] if $self->{utf8} && (!ref $self->{utf8} || $self->{utf8}{$field});

   if ($self->{delay}) {
      $self->{_store}{$field} = \($self->{_cache}{$field} = $value[0]);
   } else {
      $self->_sequence unless $self->{where}[1];
      sql_exec $self->dbh, "update $self->{table} set $field = ? where $self->{where}[0] = ?",  $value[0], $self->{where}[1];
   }
}

# we do not officially support iterators yet, but define them so we can display this object
sub FIRSTKEY {
   my $self = shift;
   keys %{$self->{_cache}};
   each %{$self->{_cache}};
}

sub NEXTKEY {
   my $self = shift;
   each %{$self->{_cache}};
}

sub EXISTS {
   my $self = shift;
   my $field = shift;
   exists $self->{_cache}{$field} or do {
      # do it the slow way. not sure wether the limit 0 is portable or not
      my $st = sql_exec $self->{database}->dbh,
                        "select * from $self->{table} limit 0";
      my %f; @f{@{$st->{NAME_lc}}} = ();
      $st->finish;
      exists $f{lc $field};
   };
}

=item $key = $hd->id

Returns the key for the selected row, creating it if necessary.

=cut

sub id($) {
   my $self = shift;
   $self->_sequence;
   $self->{where}[1];
}

=item $hd->flush

Flush all pending store operations.

=cut

# should be optimized into one sql statement

sub flush {
   my $self = shift;

   my $store = delete $self->{_store};

   if (%$store) {
      if ($self->{where}[1]) {
         sql_exec $self->dbh,
                  "update $self->{table} set" .
                     (join ",", map " $_ = ?", keys %$store) .
                  " where $self->{where}[0] = ?",
                  (map $$_, values %$store), $self->{where}[1];
      } else {
         $self->{where}[1] = sql_insertid
            sql_exec $self->dbh,
                  "insert into $self->{table} (" .
                     (join ",", keys %$store) .
                  ") values (" .
                     (join ",", map "?", keys %$store) .
                  ")",
                  (map $$_, values %$store);
      }
   }
}

=item $hd->dirty

Return true when there are store operations that are delayed. Call
C<flush> to execute these.

=cut

sub dirty {
   my $self = shift;
   !!%{$self->{_store}};
}

=item $hd->invalidate

Empties any internal caches. The next access will reload the values
from the database again. Any dirty values will be discarded.

=cut

sub invalidate {
   my $self = shift;
   delete $self->{_cache};
   delete $self->{_store};
}

=item $hd->discard

Discard all pending store operations. Only sensible when C<delay> is true.

=cut

sub discard {
   my $self = shift;
   delete $self->{_store};
}

=item $hd->delete

Delete the row from the database

=cut

sub delete {
   my $self = shift;

   $self->discard;
   if (defined $self->{where}[1]) {
      sql_exec $self->dbh,
               "delete from $self->{table} where $self->{where}[0] = ?",
               delete $self->{where}[1];
   }
   $self->dirty;
}

sub DESTROY {
   my $self = shift;

   if ($self->{autocommit}) {
      local $@; # do not erase valuable error information (like upcalls ;)
      eval { $self->flush };
      warn "$@, during PApp::DataRef object destruction" if $@;
   }
}

package PApp::DataRef::DB_row::Proxy;

# merely a proxy class to re-route method calls

sub AUTOLOAD {
   my $package = ref tied %{$_[0]};
   (my $method = $AUTOLOAD) =~ s/.*(?=::)/$package/se;
   *{$AUTOLOAD} = sub {
      unshift @_, tied %{+shift};
      goto &$method;
   };
   goto &$AUTOLOAD;
}

sub DESTROY { }

=back

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

