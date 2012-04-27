package Copilot::Plugin::SystemMonitor;

=head1 NAME Copilot::Plugin::SystemMonitor

=head1 DESCRIPTION

Plugin which sends system data to Co-Pilot Monitor every 60 seconds.
Plugin collects following data:
  * System load (uptime)
  * Disk usage (df)
  * Network usage (/proc/net/dev)
  * Memory usage (free)

This class is a child of Copilot::Plugin, and requires no options to be passed
directly to the plugin, but it is required to pass 'MonitorAddress' to the container.
All data is reported in megabytes.

Example of instantiation:
     my $jm = Copilot::Container::XMPP->new({
                                                Component      => 'Agent',
                                                JabberID       => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain   => $jabberDomain,
                                                JabberServer   => $jabberServer,
                                                MonitorAddress => $monitorAddress,
                                                Plugins => {
                                                             SystemMonitor => {},
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

@ISA = ('Copilot::Plugin');

sub _init
{
    my $self = shift;
    my $options = shift;

    $self->_loadConfig($options);

    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,

                                                pluginReportDiskUsage    => \&pluginReportDiskUsage,
                                                pluginReportNetworkUsage => \&pluginReportNetworkUsage,
                                                pluginReportRAMUsage     => \&pluginReportRAMUsage,
                                                pluginReportSystemLoad   => \&pluginReportSystemLoad,
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

    ($self->{'MONITOR_HANDLER'} = $options->{'MONITOR_HANDLER'}
      or die "MONITOR_HANDLER is not specified. Can't talk with the Monitor.\n");

    ($self->{'MONITOR_VALUE_HANDLER'} = $options->{'MONITOR_VALUE_HANDLER'}
      or die "MONITOR_VALUE_HANDLER is not specified.\n");

    ($self->{'TIMING_START_HANDLER'} = $options->{'TIMING_START_HANDLER'}
      or die "TIMING_START_HANDLER is not specified.\n");

    ($self->{'TIMING_STOP_HANDLER'} = $options->{'TIMING_STOP_HANDLER'}
      or die "TIMING_STOP_HANDLER is not specified.\n");

    # used as an extra sanity check
    $self->{'MONITOR_ADDRESS'} = $options->{'PLUGIN_OPTIONS'}->{'MonitorAddress'} || '';
}

sub mainStartHandler
{
    my ($kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;

    $kernel->alias_set ($self->{'PLUGIN_NAME'});

    my $monitorAddress = $self->{'MONITOR_ADDRESS'};
    if ( defined ($monitorAddress) && $monitorAddress ne '' )
    {
        $kernel->delay ( pluginReportDiskUsage    => 60 );
        $kernel->delay ( pluginReportNetworkUsage => 61 );
        $kernel->delay ( pluginReportRAMUsage     => 62 );
        $kernel->delay ( pluginReportSystemLoad   => 63 );
    }
    else
    {
        my $container = $self->{'CONTAINER_ALIAS'};
        my $logHandler = $self->{'LOG_HANDLER'};
        $kernel->post ($container, $logHandler, "[Monitor] Monitoring has been disabled for this session (missing configuration).");
    }
}

sub mainStopHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
}

sub pluginReportDiskUsage
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $reportValueHandler = $self->{'MONITOR_VALUE_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $kernel->post ($container, $logHandler, "[Monitor] Reporting disk usage.");

    my $diskUsage = Copilot::Util::getDiskUsage ();
    foreach my $disk (keys %$diskUsage)
    {
        my $used      = $diskUsage->{$disk}->{'used'};
        my $available = $diskUsage->{$disk}->{'available'};
        $kernel->post ($container, $reportValueHandler, 'system.disk.used.'      . $disk, $used);
        $kernel->post ($container, $reportValueHandler, 'system.disk.available.' . $disk, $available);
        $kernel->post ($container, $logHandler, "[Monitor] Status of disk $disk: $available/$used.", 'debug');
    }

    $kernel->delay (pluginReportDiskUsage => 60);
}

sub pluginReportNetworkUsage
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $reportValueHandler = $self->{'MONITOR_VALUE_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $kernel->post ($container, $logHandler, "[Monitor] Reporting network traffic.");

    my $netIO = Copilot::Util::getNetworkUsage ();
    foreach my $netInterface (keys %$netIO)
    {
        my $in  = $netIO->{$netInterface}->{'in'};
        my $out = $netIO->{$netInterface}->{'out'};
        my $prevValues = $self->{'prevNetValues'}->{$netInterface};
        unless ( defined ($prevValues) )
        {
            $prevValues = [$in, $out];
        }
        my ($prevIn, $prevOut) = @$prevValues;

        $kernel->post ($container, $reportValueHandler, 'system.net.in.'  . $netInterface,  abs ($prevIn - $in));
        $kernel->post ($container, $reportValueHandler, 'system.net.out.' . $netInterface, -abs ($prevOut - $out));
        $kernel->post ($container, $logHandler, "[Monitor] Network traffic on $netInterface: $in/$out.", 'debug');

        $self->{'prevNetValues'}->{$netInterface} = [$in, $out];
    }

    $kernel->delay (pluginReportNetworkUsage => 60);
}

sub pluginReportRAMUsage
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $reportValueHandler = $self->{'MONITOR_VALUE_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $kernel->post ($container, $logHandler,"[Monitor] Reporting memory usage.");

    my $ramUsage = Copilot::Util::getRAMUsage ();
    foreach my $memComp (keys %$ramUsage)
    {
        my $used      = $ramUsage->{$memComp}->{'used'};
        my $available = $ramUsage->{$memComp}->{'available'};
        $kernel->post ($container, $reportValueHandler, 'system.ram.used.'      . $memComp, $used);
        $kernel->post ($container, $reportValueHandler, 'system.ram.available.' . $memComp, $available);
        $kernel->post ($container, $logHandler, "[Monitor] $memComp usage: $available/$used.", 'debug');
    }

    $kernel->delay (pluginReportRAMUsage => 60);
}

sub pluginReportSystemLoad
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $reportValueHandler = $self->{'MONITOR_VALUE_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};

    my @loadAvgs =  Copilot::Util::getCPULoad ();
    my $oneMinAvg = $loadAvgs[1];
    $kernel->post ($container, $reportValueHandler, 'system.load.1min',  $oneMinAvg);
    $kernel->post ($container, $reportValueHandler, 'system.load.5min',  $loadAvgs[1]);
    $kernel->post ($container, $reportValueHandler, 'system.load.15min', $loadAvgs[2]);
    $kernel->post ($container, $logHandler, "[Monitor] System load of $oneMinAvg in past minute has been reported.");

    $kernel->delay (pluginReportSystemLoad => 60);
}

"M";

