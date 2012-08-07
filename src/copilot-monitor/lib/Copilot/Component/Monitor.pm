package Copilot::Component::Monitor;

=head1 NAME Copilot::Component::Monitor;

=head1 DESCRIPTION

This class implements the Co-Pilot monitoring functionality, collecting event data from other components and storing them into the database. It's a child class of Copilot::Component. The component must be instantiated within one of the component containers (eg. Copilot::Container:XMPP). The following data has to be provided via 'ComponentOptions' parameter:

  CarbonServer - Address of the server on which Carbon (Graphite) is running.
  CarbonPort   - Port on which the Carbon is accessible. (default: 2023).
  MongoDBServer - Address of the server on which MongoDB is running.
  MongoDBPort   - Port to which MongoDB is bound. (default: 27017)

  Example instantiation:
  my $mon = new Copilot::Container::XMPP ({
                                            Component       => 'Monitor',
                                            LoggerConfig    => $loggerConfig,
                                            JabberID        => $jabberID,
                                            JabberPassword  => $jabberPW,
                                            JabberDomain    => $jabberDomain,
                                            JabberServer    => $jabberServer,
                                            ComponentOptions => {
                                                                  CarbonServer  => $carbonServer,
                                                                  CarbonPort    => $carbonPort,
                                                                  MongoDBServer => $mongoDBServer,
                                                                  MongoDBPort   => $mongoDBPort
                                                                },
                                         });
=cut

use strict;
use warnings;

use vars qw (@ISA);
our $VERSION="0.1";

use Copilot::Component;
use Copilot::GUID;

use POE;
use POE::Component::Logger;

use Data::Dumper;

use Time::HiRes qw(time);
use IO::Socket;
use List::Util qw(min max sum reduce);

use boolean;
use JSON;
use DateTime;
use MongoDB;

@ISA = ("Copilot::Component");

# Initializes the component
sub _init
{
    my $self    = shift;
    my $options = shift;

    # Read configuration
    $self->_loadConfig($options);

    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start                              => \&mainStartHandler,
                                                _stop                               => \&mainStopHandler,

                                                $self->{'COMPONENT_INPUT_HANDLER'}  => \&componentInputHandler,
                                                componentProcessInput               => \&componentProcessInput,
                                                componentIncrementEventCounter      => \&componentIncrementEventCounter,
                                                componentDecrementEventCounter      => \&componentDecrementEventCounter,
                                                componentStoreEventDuration         => \&componentStoreEventDuration,
                                                componentStoreValue                 => \&componentStoreValue,
                                                componentUpdateDB                   => \&componentUpdateDB,
                                                componentStoreEventDetails => \&componentStoreEventDetails,
                                                componentUpdateEventDetails => \&componentUpdateEventDetails,
                                             },
                            args =>          [ $self ],
                         );

    return $self;
}

# Loads configuration into $self
sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    $self->{'COMPONENT_NAME'} = $options->{'COMPONENT_NAME'};

    # Server's session alias
    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
      or die "CONTAINER_ALIAS is not specified. Can't communicate with server!\n";

    # Event which handles the input inside the monitor
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentInputHandler';

    $self->{'LOG_HANDLER'} = ($options->{'COMPONENT_LOG_HANDLER'} || 'logger');

    # Event which handles the messages sent from component to the outside world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n";

    ($self->{'CARBON_SERVER'} = $options->{'COMPONENT_OPTIONS'}->{'CarbonServer'})
        or die "CARBON_SERVER is not specified.\n";

    $self->{'CARBON_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'CarbonPort'} || '2003');

    ($self->{'MONGODB_SERVER'} = $options->{'COMPONENT_OPTIONS'}->{'MongoDBServer'})
        or die "MONGODB_SERVER is not specified.\n";

    $self->{'MONGODB_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'MongoDBPort'} || '27017');
}

sub mainStartHandler
{
    my ($kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;

    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    # Socket connection used for feeding Carbon server with the data
    $heap->{'carbonSocket'} = new IO::Socket::INET (
                                                      PeerAddr => $self->{'CARBON_SERVER'},
                                                      PeerPort => $self->{'CARBON_PORT'},
                                                      Proto    => 'tcp',
                                                   );

    # a hash of event counters
    $heap->{'eventCounters'} = {};
    # a hash of events that are currently running ('startEvent' message was sent)
    $heap->{'eventDurations'} = {};

    # data is flushed to the DB every 10 seconds
    $heap->{'dbUpdateAlarmID'} = $kernel->delay (componentUpdateDB => 10);

    $heap->{'mongoConn'} = MongoDB::Connection->new(host => $self->{'MONGODB_SERVER'} . ":" . $self->{'MONGODB_PORT'});
    $heap->{'mongoDB'} = $heap->{'mongoConn'}->copilot;
    $heap->{'mongoColl'} = $heap->{'mongoDB'}->connections;
}

# Called when session is being closed
sub mainStopHandler
{
    my ($kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    print "Stopping the Monitor component.\n";

    $kernel->alarm_remove ($heap->{'dbUpdateAlarmID'});
    close ($heap->{'carbonSocket'});
}

sub getInputHandler
{
    my $self = shift;
    return $self->{'COMPONENT_INPUT_HANDLER'};
}

sub componentInputHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    $kernel->yield('componentProcessInput', $input);
}

sub componentProcessInput
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    my $command = $input->{'command'};

    if($command eq 'reportEvent')
    {
      $kernel->yield('componentIncrementEventCounter', $input);
    }
    elsif($command eq 'reportEventDuration')
    {
      $kernel->yield('componentStoreEventDuration', $input);
    }
    elsif($command eq 'reportEventValue')
    {
      $kernel->yield('componentStoreValue', $input);
    }
    elsif($command eq 'storeEventDetails')
    {
      $kernel->yield('componentStoreEventDetails', $input);
    }
    elsif($command eq 'updateEventDetails')
    {
      $kernel->yield('componentUpdateEventDetails', $input);
    }
}

# Increments the event counter
sub componentIncrementEventCounter
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $component = $input->{'component'};
    my $eventType = $input->{'event'};

    $heap->{'eventCounters'}->{$component}->{$eventType}++;

    $kernel->post ($container, $logHandler, "Increased event counter of copilot.$component.$eventType", 'debug');
}

# Decrements event counter (not used anywhere at the moment)
sub componentDecrementEventCounter
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $component = $input->{'component'};
    my $eventType = $input->{'event'};

    $heap->{'eventCounters'}->{$component}->{$eventType}--;
    $kernel->post ($container, $logHandler, "Decreased event counter of copilot.$component.$eventType", 'debug');
}

sub componentStoreEventDuration
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $component = $input->{'component'};
    my $eventType = $input->{'event'};
    my $duration  = $input->{'duration'} + 0.0;

    # this is done from 'client'-side
    # $heap->{'eventCounters'}->{$component}->{$eventType}++;

    my $durations = $heap->{'eventDurations'}->{$component}->{$eventType};
    if ( ref ($durations) ne 'ARRAY' )
    {
      $durations = $heap->{'eventDurations'}->{$component}->{$eventType} = [];
    }

    # duration is converted into minutes (time() reports in seconds)
    push (@$durations, $duration / 60);
    $kernel->post ($container, $logHandler, "Appending $duration to sample for copilot.$component.$eventType", 'debug');
}

# Immediately writes data to the database
sub componentStoreValue
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $carbonSocket = $heap->{'carbonSocket'};
    my $timestamp    = int (time ());
    my $component    = $input->{'component'};
    my $event        = $input->{'event'};
    my $value        = $input->{'value'};
    my $data         = "copilot.$component.$event $value $timestamp";

    print $carbonSocket $data . "\n";

    $kernel->post($container, $logHandler, "Sending value to Carbon: $data.", 'debug');
}

# Flushes collected data to Carbon
sub componentUpdateDB
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $carbonSocket = $heap->{'carbonSocket'};
    my $timestamp    = int (time ());
    my @updates      = ();
    my $totalUpdates = 0;

    # preparing strings which will be sent to Carbon,
    # the format of an update is:
    # <graph path> <new value> <timestamp>\n
    my $eventCounters = $heap->{'eventCounters'};
    my $component;
    my $updatedEvents;
    my $event;

    foreach $component (keys %$eventCounters)
    {
      $updatedEvents = $eventCounters->{$component};

      foreach $event (keys %$updatedEvents)
      {
        my $counterValue = $updatedEvents->{$event};

        if ( $counterValue > 0 )
        {
          push (@updates, "copilot.$component.$event $counterValue $timestamp");
          $heap->{'eventCounters'}->{$component}->{$event} = 0;
        }
      }
    }
    $totalUpdates = @updates;

    my $eventDurations = $heap->{'eventDurations'};
    foreach $component (keys %$eventDurations)
    {
      $updatedEvents = $eventDurations->{$component};

      foreach $event (keys %$updatedEvents)
      {
        my $durations = $updatedEvents->{$event};
        my $count = scalar @$durations;

        if($count > 0)
        {
          my $avg = (sum @$durations) / $count;
          my $min = min @$durations;
          my $max = max @$durations;
          my $gmean = (reduce { $a * $b } @$durations) ** (1 / $count);

          push (@updates, "copilot.$component.$event.avg $avg $timestamp");
          push (@updates, "copilot.$component.$event.min $min $timestamp");
          push (@updates, "copilot.$component.$event.max $max $timestamp");
          push (@updates, "copilot.$component.$event.gmean $gmean $timestamp");
          push (@updates, "copilot.$component.$event.count $count $timestamp");

          $heap->{'eventDurations'}->{$component}->{$event} = [];
          $totalUpdates++;
        }
      }
    }

    push (@updates, "copilot.monitor.updates $totalUpdates $timestamp\n");
    print $carbonSocket (join ("\n", @updates));

    if($totalUpdates > 0)
    {
        $kernel->post ($container, $logHandler, "Sent $totalUpdates updates to Carbon.");
    }

    $heap->{'dbUpdateAlarmID'} = $kernel->delay (componentUpdateDB => 10);
}

sub componentStoreEventDetails
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $mongoColl = $heap->{'mongoColl'};
    my $details   = $input->{'details'};

    if(length($details) > 0)
    {
        my $json = JSON->new->allow_blessed->convert_blessed->filter_json_object(\&helperFilterJsonObject);
        $details = $json->decode($details);
        my $now = DateTime->now;
        $details->{'created_at'} = $now;
        $details->{'updated_at'} = $now;
        my $id = $mongoColl->insert($details);

        $id = $id->to_string;
        $kernel->post($container, $logHandler, "Stored new event details. Document id: $id", 'debug');
    }
}

sub componentUpdateEventDetails
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $mongoColl = $heap->{'mongoColl'};
    my $session = $input->{'session'};
    my $updates = $input->{'updates'};

    if (length($session) > 0 && length($updates) > 0)
    {
        my $query = {'agent_data.uuid' => $session, 'connected' => boolean::true};
        my $json = JSON->new->allow_blessed->convert_blessed->filter_json_object(\&helperFilterJsonObject);
        $updates = $json->decode($updates);
        $mongoColl->update($query, $updates);
        $mongoColl->update($query, {'$set' => {'updated_at' => DateTime->now}});

        $kernel->post($container, $logHandler, "Updated details for event $session.", 'debug');
    }
}

# Decodes the boolean values into a format MongoDB expects
sub helperFilterJsonObject
{
    my ($obj) = @_;

    for my $key (keys %$obj)
    {
        my $value = $obj->{$key};
        $obj->{$key} = boolean::true if $value eq "true";
        $obj->{$key} = boolean::false if $value eq "false";
    }

    return ();
}
