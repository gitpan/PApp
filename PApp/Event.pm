=head1 NAME

PApp::Event - catch/broadcast various events

=head1 SYNOPSIS

 use PApp::Event;

=head1 DESCRIPTION

None yet. Experimental.

=over 4

=cut

package PApp::Event;

require 5.006;

use PApp::SQL;
use PApp::Config qw($DBH);
use Compress::LZF ':freeze';

#use base 'Exporter';

$VERSION = 0.142;

=item on "event_type" => \&coderef

Register a handler that is called on the named event. The handler will
receive the C<event_type> as first argument. The remaining arguments
consist of all the scalars that have been broadcasted (i.e. multiple
events of the same type get "bundled" into one call), sorted in the order
of submittal, i.e. the newest event data comes last.

=cut

sub on ($&) {
   push @{$handler{$_[0]}}, $_[1];
}

=item broadcast "event_type" => $data

Broadcast an event of the named type, together with a single scalar.

=cut

sub broadcast($$) {
   my $event = $_[0];
   my $data = sfreeze_cr $_[1];

   sql_exec $DBH, "lock tables event write, event_count write";

   my $id = sql_insertid
      sql_exec $DBH,
               "insert into event (id, ctime, event, data) values (NULL,NULL,?,?)",
               $event, $data;

   sql_exec $DBH, "update event_count set count = ? where count < ?", $id, $id;

   sql_exec $DBH, "unlock table";

   handle_events($id);
}

sub handle_event {
   &$_ for @{$handler{$_[0]}};
}

sub handle_events {
   my $new_count = $_[0];

   my $st = sql_exec $DBH,
                     \my($event, $data),
                     "select event, data
                      from event
                      where id > ? and id <= ?
                      order by id, event",
                     $PApp::event_count, $new_count;
   $PApp::event_count = $new_count;

   my $levent;
   my @ldata;

   while ($st->fetch) {
      if ($levent ne $event) {
         PApp::Event::handle_event($levent, @ldata) if @ldata;
         $levent = $event;
         @ldata = ();
      }
      push @ldata, sthaw $data;
   }

   PApp::Event::handle_event($levent, @ldata) if @ldata;
}

=head1 SEE ALSO

L<PApp>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

