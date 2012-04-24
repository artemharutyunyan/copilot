package Copilot::Component::Monitor;

=head1 NAME Copilot::Component::Monitor;

=head1 DESCRIPTION

This class implements the Co-Pilot monitoring functionality, collecting event data from other components and storing them into the database. It's a child class of Copilot::Component. The component must be instantiated within one of the component containers (eg. Copilot::Container:XMPP). The following data has to be provided via 'ComponentOptions' parameter:

  CarbonServer - Address of the server on which Carbon (Graphite) is running.
  CarbonPort   - Port on which the Carbon is accessible. (default: 2023).

  Example instantiation:
  my $mon = new Copilot::Container::XMPP ({
                                            Component       => 'Monitor',
                                            LoggerConfig    => $loggerConfig,
                                            JabberID        => $jabberID,
                                            JabberPassword  => $jabberPW,
                                            JabberDomain    => $jabberDomain,
                                            JabberServer    => $jabberServer,
                                            ComponentOptions => {
                                                                  CarbonServer => $carbonServer,
                                                                  CarbonPort   => $carbonPort,
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

    ($self->{'CARBON_PORT'} = $options->{'COMPONENT_OPTIONS'}->{'CarbonPort'} or '2003');
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

    $kernel->post ($container, $logHandler, "Sent $totalUpdates updates to Carbon.");
    $heap->{'dbUpdateAlarmID'} = $kernel->delay (componentUpdateDB => 10);
}
