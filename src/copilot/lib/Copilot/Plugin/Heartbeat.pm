package Copilot::Plugin::Heartbeat;

=head1 NAME Copilot::Plugin::Heartbeat

=head1 DESCRIPTION

This plugin is used for remote system introspection.

This class is a child of Copilot::Plugin, the plugin requires following options:

    ChatAddress - JID address of the chat room. (required)

Besides the 'ChatAddress' options, for proper functioning it is required to pass
the following options to the container:

    ChatServer  - domain name of the MUC server (e.g. conference.localhost)
    ChatRoom    - name of the chat room which the component should join

Example of instantiation:
     my $jm = Copilot::Container::XMPP->new({
                                                Component      => 'Agent',
                                                JabberID       => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain   => $jabberDomain,
                                                JabberServer   => $jabberServer,
                                                ChatServer     => $chatServer,
                                                ChatRoom       => $chatRoom,
                                                Plugins => {
                                                             Heartbeat => { 'ChatAddress' => $chatRoom . '@' . $chatServer, },
                                                           },
                                            });

=cut

use strict;
use warnings;

use vars qw (@ISA);
our $VERSION = '0.01';

use Copilot::Plugin;
use Copilot::Util;

use POE;
use POE::Component::Logger;

use Data::Dumper;

@ISA = ('Copilot::Plugin');

sub _init
{
    my $self = shift;
    my $options = shift;

    $self->_loadConfig ($options);

    my $inputHandler = $self->{'INPUT_HANDLER'};
    POE::Session->create (
                inline_states => {
                                  _start => \&mainStartHandler,
                                  _stop  => \&mainStopHandler,

                                  $inputHandler     => \&pluginProcessInputHandler,

                                  reportSystemLoad        => \&pluginReportSystemLoad,
                                  reportDiskUsage         => \&pluginReportDiskUsage,
                                  reportRunningProcesses  => \&pluginReportRunningProcesses,
                                  reportMemoryUsage       => \&pluginReportMemoryUsage,

                                  pong              => \&pluginPongHandler,
                                },
                args => [ $self ],
               );
    return $self;
}

sub _loadConfig
{ 
    my $self = shift;
    my $options = shift;

    $self->{'PLUGIN_NAME'} = $options->{'PLUGIN_NAME'};

    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
      or die "CONTAINER_ALIAS is not specified. Can't communicate with server.\n";

    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
      or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n";

    $self->{'LOG_HANDLER'} = $options->{'CONTAINER_LOG_HANDLER'} || 'logger';

    $self->{'INPUT_HANDLER'} = 'processInput';

    # used as an extra sanity check
    $self->{'CHAT_ROOM_ADDRESS'} = $options->{'PLUGIN_OPTIONS'}->{'ChatRoomAddress'} || '';
}

sub mainStartHandler
{
    my ($kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;

    $kernel->alias_set ($self->{'PLUGIN_NAME'});

    my $chatAddress = $self->{'CHAT_ROOM_ADDRESS'};
    if ( !defined ($chatAddress) || $chatAddress eq '@' || $chatAddress eq '' )
    {
        my $container = $self->{'CONTAINER_ALIAS'};
        my $logHandler = $self->{'LOG_HANDLER'};
        $kernel->post ($container, $logHandler, "[Heartbeat] This component won't be reachable by the Heartbeat service (missing configuration).");
    }
}

sub mainStopHandler
{
}

sub getInputHandler
{
    my $self = shift;
    return $self->{'INPUT_HANDLER'};
}

sub pluginProcessInputHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};
    
    my $command     = $input->{'command'};
    my $from        = $input->{'from'};

    if ( $command eq 'Heartbeat:getStatus' )
    {
      my $component = ucfirst $input->{'component'};

      $kernel->yield('report' . $component, $from);
      $kernel->post ($container, $logHandler, "[Heartbeat] Reporting $component to $from.");
    }
    elsif ( $command eq 'Heartbeat:ping' )
    {
      $kernel->yield('pong', $from);
      $kernel->post ($container, $logHandler, "[Heartbeat] Received a ping from $from.");
    }
    else
    {
      $kernel->post ($container, $logHandler, "[Heartbeat] Received an unknown command: $command. Ignoring.", 'debug');
      return;
    }
}

sub pluginReportSystemLoad
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my @load = Copilot::Util::getCPULoad();
    my $response = {
                      '1min'  => $load[0],
                      '5min'  => $load[1],
                      '15min' => $load[2],
                   };

    my $status = {
                    'to'    => $to,
                    'info'  => {
                                  'command'     => 'haveStatus',
                                  'component'   => 'systemLoad',
                                  'status'      => Copilot::Util::hashToString ($response),
                               },
                 };

    $kernel->post ($container, $sendHandler, $status);
}

sub pluginReportDiskUsage
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $usage       = Copilot::Util::getDiskUsage();
    my @devices     = [];

    for my $device (keys %$usage)
    {
        my $data = $usage->{$device};
        my $path = $data->{'path'};

        # we're only interested in physical drives
        push (@devices, $data) if index ($path, '/dev') == 0;
    }

    my $response = Copilot::Util::groupHashesByKeys (@devices);
    
    my $status = {
                    'to'    => $to,
                    'info'  => {
                                  'command'     => 'haveStatus',
                                  'component'   => 'diskUsage',
                                  'status'      => Copilot::Util::hashToString ($response),
                               },
                 };

    $kernel->post ($container, $sendHandler, $status);
}

sub pluginReportRunningProcesses
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my @processes = Copilot::Util::getRunningProcesses();
    my $response = Copilot::Util::groupHashesByKeys (@processes);

    delete $response->{'user'};
    delete $response->{'pid'};
    delete $response->{'vsz'};
    delete $response->{'tty'};
    delete $response->{'stat'};
    delete $response->{'start'};

    my $status = {
                    'to'    => $to,
                    'info'  => {
                                  'command'     => 'haveStatus',
                                  'component'   => '',
                                  'status'      => Copilot::Util::hashToString ($response),
                               },
                 };

    $kernel->post ($container, $sendHandler, $status);
}


sub pluginReportMemoryUsage
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $memoryUsage = Copilot::Util::getRAMUsage();
    my @usage = [];
    foreach my $component (keys %$memoryUsage)
    {
        my $data = $memoryUsage->{$component};
        $data->{'memory'} = $component;
        push (@usage, $data);
    }
    my $response = Copilot::Util::groupHashesByKeys(@usage);

    my $status = {
                    'to'    => $to,
                    'info'  => {
                                  'command'     => 'haveStatus',
                                  'component'   => 'memoryUsage',
                                  'status'      => Copilot::Util::hashToString ($response),
                               },
                 };

    $kernel->post ($container, $sendHandler, $status);
}

=begin template

sub pluginReport
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self        = $heap->{'self'};
    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my @load = Copilot::Util::getCPULoad();
    my $response = {
                      
                   };

    my $status = {
                    'to'    => $to,
                    'info'  => {
                                  'command'     => 'haveStatus',
                                  'component'   => '',
                                  'status'      => Copilot::Util::hashToString ($response),
                               },
                 };

    $kernel->post ($container, $sendHandler, $status);
}

=cut

sub pluginPongHandler
{
    my ($kernel, $heap, $to) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $pong = {
                  'to'    => $to,
                  # message itself is an acknowledgement
                  'noack' => '1',
                  'info'  => {
                                'command' => 'pong',
                             },
               };

    $kernel->post ($container, $sendHandler, $pong);
}
