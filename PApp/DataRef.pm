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

$VERSION = 0.08;

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

=item $hd = new PApp::DataRef 'File', path => ..., perm => ...;

Create a new handle that fetches and stores a file. NYI.

=cut

sub new {
   my $class = shift;

   my $type = "PApp::DataRef::".shift;

   unless (defined &{"${type}::new"}) {
      eval "use $type"; die $@ if $@;
   }

   $type->new(@_);
}

package PApp::DataRef::Base;

use Carp ();

sub TIESCALAR {
   my $class = shift;
   bless shift, $class;
}

sub FETCH { Carp::croak "FETCH not implemented for ".ref $_[0] }
sub STORE { Carp::croak "STORE not implemented for ".ref $_[0] }

sub DESTROY { }

package PApp::DataRef::DB_row_field;

@ISA = PApp::DataRef::Base::;

sub FETCH {
   my $self = shift;
   my $value = $self->{row}->_fetch($self->{field});
   $value = $self->{fetch}($self, $value) if exists $self->{fetch};
   $value;
}

sub STORE {
   my $self = shift;
   my $value = shift;
   if (exists $self->{store}) {
      my @value = $self->{store}($self, $value);
      return unless @value;
      $value = $value[0];
   }
   $self->{row}->_store($self->{field}, $value);
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

sub TIEHASH {
   my $class = shift;
   my %a = @_;

   exists $a{autocommit} or $a{autocommit} = 1;

   exists $a{table} or Carp::croak("mandatory parameter table missing");
   exists $a{where} or Carp::croak("mandatory parameter where missing");

   if (my $preload = delete $a{preload} and defined $a{where}[1]) {
      # try to preload, enabled caching
      $preload = ref $preload ? join ",", @$preload : "*";
      my $st = sql_exec "select $preload from $a{table}";
      my $hash = $st->fetchrow_hashref;
      $a{_cache}{$field} = $value while my ($field, $value) = each %$hash;
      $st->finish;
   }

   my $self = bless \%a, $class;
}

=item $hd->{fieldname} or $hd->{[fieldname, extra-args]}

Return a reference to the given field of the row. The optional arguments
C<fetch> and C<store> can be given code-references that are called at
every fetch and store, and should return their first argument (possibly
modified), e.g. to fetch and store a crypt'ed password field:

  my $pass_fetch = register_callback { "" };
  my $pass_store = register_callback { crypt $_[1], <salt> };

  $hd->refer("password", fetch => $pass_fetch->(), store => $pass_store->());

Additional named parameters are:

  fetch => coderef($self, $value) => value
  store => coderef($self, $value) => value

     Functions that should be called with the fetched/to-be-stored value
     as second argument that should be returned, probably after some
     transformations have been used on it. This can be used to convert
     sql-sets or password fields from/to their internal database format.

     If the store function returns nothing (an empty 'list', as it is
     called in lsit context), the update is being skipped.

     L<PApp::Callback> for a way to create serializable code references.

  filter => <predefined filter name>
     
     PApp::DataRef::DB_row predefines some filter types:

        sql_set   converts strings of the form a,b,c into array-refs and
                  vice versa.

        password  returns the empty string and crypt's the value if nonempty.

=cut

use PApp::Callback;

my $sql_set_fetch = register_callback {
   [split /,/, $_[1]];
} name => __PACKAGE__."-sql_set_fetch";

my $sql_set_store = register_callback {
   join ",", @{$_[1]};
} name => __PACKAGE__."-sql_set_store";

my $sql_pass_fetch = register_callback {
   "";
} name => __PACKAGE__."-sql_pass_fetch";

my $sql_pass_store = register_callback {
   $_[1] ne "" ? crypt $_[1], join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64] : ();
} name => __PACKAGE__."-sql_pass_store";

my %filter = (
   sql_set  => [ fetch => $sql_set_fetch->(),  store => $sql_set_store->()  ],
   password => [ fetch => $sql_pass_fetch->(), store => $sql_pass_store->() ],
);

sub refer {
   my $self = shift;
   if (ref $_[0]) {
      @_ = @{$_[0]};
   }

   my $self = { row => $self, "field", @_ };

   if (my $filter = delete $self->{filter}) {
      Carp::croak("refer called with undefined filter type '$filter'") unless exists $filter{$filter};
      %$self = (%$self, @{$filter{$filter}});
   }

   my $scalar;
   tie $scalar, PApp::DataRef::DB_row_field, $self;
   \$scalar;
}

*FETCH = \&refer;

sub STORE {
   Carp::croak ref($_[0])." is readonly";
}

sub _fetch {
   my ($self, $field) = @_;
   if (exists $self->{_cache}{$field}) {
      return $self->{_cache}{$field};
   } else {
      if ($self->{where}[1]) {
         my $value = sql_fetch "select $field from $self->{table} where $self->{where}[0] = ?",  $self->{where}[1];
         $self->{_cache}{$field} = $value if $self->{cache};
         $value;
      } else {
         ();
      }
   }
}

sub _sequence {
   my $self = shift;

   unless (defined $self->{where}[1]) {
      # create a new ID
      sql_exec "insert into $self->{table} values ()";
      $self->{where}[1] = sql_insertid;
   }
}

sub _store {
   my ($self, $field, $value) = @_;
   if ($self->{delay}) {
      $self->{_store}{$field} = \($self->{_cache}{$field} = $value);
   } else {
      $self->_sequence unless defined $self->{where}[1];
      sql_exec "update $self->{table} set $field = ? where $self->{where}[0] = ?",  $value, $self->{where}[1];
   }
}

=item $hd->flush

Flush all pending store operations.

=cut

# should be optimized into one sql statement

sub flush {
   my $self = shift;

   $self->_sequence;

   my $store = delete $self->{_store};

   if (%$store) {
      sql_exec "update $self->{table} set" .
               (join ",", map " $_ = ?", keys %$store) .
               " where $self->{where}[0] = ?",
               (map $$_, values %$store), $self->{where}[1];
   }
}

=item $hd->discard

Discard all pending store operations. Only sensible when C<delay => 1>.

=cut

sub discard {
   my $self = shift,
   delete $self->{_store};
}

sub DESTROY {
   my $self = shift;

   $self->flush if $self->{autocommit};
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

=head1 BUGS

 - requires mysql auto_increment feature for auto-insertions.

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

