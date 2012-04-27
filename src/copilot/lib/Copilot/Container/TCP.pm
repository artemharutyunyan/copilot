package Copilot::Container::TCP;

=pod

=head1 NAME Copilot::Container::TCP

=head1 DESCRIPTION

Container class for a TCP server. Copilot::Container::TCP is a child of Copilot::Container class. This class creates a listeing TCP socket and also allows to 
open client sockets to send data. The class also provides logging for the component.

Please also see the documentation of Copilot::Container

=cut

=head1 METHODS


=item new($options)

Constructor for Copilot::Container::TCP class. Takes as an input hash reference with options. The following options can be specified:

    Component        => Name of the component which must run in the container
    LoggerConfig     => Path of the file with logger configuration (Log::Dispatch format)
    ComponentOptions => Hash reference with options which must be passed to the component.

Example usage:

    my $jm = new Copilot::Container::TCP (
                              {
                                  Component => 'JobManager',
                                  LoggerConfig => '/home/hartem/src/x/etc/JMLogger.conf',
                                  ComponentOptions => {
                                                        workDir => '/tmp/chirp',
                                                        AliEnUser => 'hartem',
                                                    },

                              }
                            );


=cut





use strict;
use warnings;

use vars qw (@ISA);

use Copilot::Container;

use POE;
use POE::Component::Server::TCP;
use POE::Filter::Reference;
use POE::Component::Logger;

use Data::Dumper;



@ISA = ("Copilot::Container");

sub _init
{
    my $self    = shift;
    my $options = shift;

    #
    # Read config 
    $self->_loadConfig($options);

    #
    # Create logger
    POE::Component::Logger->spawn(ConfigFile => $self->{'LOGGER_CONFIG_FILE'});


    #
    # Create TCP server here 
    POE::Component::Server::TCP->new (
                                        Port               => $self->{PORT},
                                        Alias              => $self->{NAME},
                                        ClientFilter       => "POE::Filter::Reference",
                                        ClientInput        => \&_clientInput,
                                        ClientDisconnected => \&_clientDisconnected,
                                        ClientError        => \&_clientError,
                                        InlineStates       => {
                                                                'log' => \&_log,
                                                              },
                                       Started            => sub { 
                                                                    $_[KERNEL]->state ('_wakeUp', $self);
                                                                    $_[KERNEL]->state ($self->{'SEND_HANDLER'}, $self);
                                                                    $_[KERNEL]->state ('_sendTCP', $self);
                                                                    $_[KERNEL]->state ('logger', $self);
                                                                    $_[KERNEL]->delay ('_wakeUp', 2 ); # wait untill the all objects are initialized and call wakeUp
#                                                                    $_[SESSION]->option (trace => 1);
                                                                 },
                                       ObjectStates       => [
                                                                $self => [
                                                                           # delivers messages from client to component
                                                                           deliverInput  => 'deliverInput',

                                                                           # delivers messages from server back to client
                                                                           $self->{'OUTPUT_HANDLER'} => 'deliverOutput',

                                                                           # if needed component can use this to register itself somewhere
                                                                           # after startup
                                                                           $self->{'SEND_HANDLER'} => 'send', 

                                                                           # writes messages to log
                                                                           $self->{'LOG_HANDLER'} => 'logger',
                                                                           
                                                                           # internal event for sending out tcp packets
                                                                           _sendTCP => '_sendTCP',  

                                                                           # internal event for waking up the component
                                                                           _wakeUp => '_wakeUp', 

                                                                           # 
                                                                         ],
                                                              ]           
                                    );
    my $module = "Copilot::Component::".$self->{COMPONENT_NAME}; 
    eval " require $module";
    if ($@)
    {
        die "Failed to load $module : $@ \n";
    }
 
     $self->{COMPONENT} = $module->new( {
                                        'COMPONENT_NAME' => $self->{'COMPONENT_NAME'},
                                        'SERVER_ALIAS' => $self->{'NAME'},
                                        'SERVER_OUTPUT_HANDLER' => $self->{'OUTPUT_HANDLER'},
                                        'SERVER_SEND_HANDLER' => $self->{'SEND_HANDLER'},
                                        'COMPONENT_OPTIONS' => $options->{'ComponentOptions'},
                                        'SERVER_LOG_HANDLER' => $self->{'LOG_HANDLER'},
                                     } 
                                    );
    return $self;
}

#
# Loads config parameters into $self
sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    # Component which will be running inside our server
    $self->{'COMPONENT_NAME'} = $options->{'Component'} || die "Component name not provided. Can not start the server.\n"; 
    
    # Will be used as an alias for POE::Session::Server::TCP
    $self->{'NAME'} = "Server_".$self->{'COMPONENT_NAME'};     

    # Port on which to listen
    $self->{'PORT'}    = $options->{'Port'} || 1984;   

    # Event name which will be used to send messages from component to this server
    $self->{'OUTPUT_HANDLER'} = 'deliverOutput'; 

    # Event name which will be used to log messages
    $self->{'LOG_HANDLER'} = 'logger'; 

    # Event name which will be used in case when the component needs to send something 
    # to the outer world.
    $self->{'SEND_HANDLER'} =  'send';

    # Logger configuration file
    $self->{'LOGGER_CONFIG_FILE'} = $options->{'LoggerConfig'} || die "Logger configuration file ton provided. Can not start the server.\n";
}


#
# Called when server gets input from from clients 
sub _clientInput 
{ 
    my ( $kernel, $input, $heap ) = @_ [ KERNEL, ARG0, HEAP ];
    my $clientIp = $heap->{remote_ip};


    $kernel->yield ('deliverInput', $input);
    $kernel->yield ('logger', "Got '". $input->{'command'} ."' from $clientIp", 'debug');
}

#
# Called when client disconnects
sub _clientDisconnected 
{
#    print "\n\nClient disconnected !!!\n\n";
}

#
# Called when there is an error in the connection
sub _clientError
{

}

#
# Delvers input from client to the component 
sub deliverInput
{
    my ($self, $heap, $kernel, $sender, $input) = @_[ OBJECT, HEAP, KERNEL, SESSION, ARG0];
    my ($componentAlias, $handler ) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getInputHandler() );

    # Dispatch the input message to the component 
    $kernel->post ($componentAlias, $handler, $input, $sender);
}

#
# Delivers output from component to the client 
sub deliverOutput
{
   my ($self, $output, $kernel, $heap) = @_ [OBJECT, ARG0, KERNEL, HEAP]; 
   #print "In deliver Output $self $output $kernel $heap\n"; 
   $heap->{client}->put ($output);
}

#
# Component can use this event to communicate with outer world 
sub send
{
    my ($self, $kernel, $input) = @_[ OBJECT, KERNEL, ARG0];    

    if ($input->{'proto'} eq 'tcp')
    {
        $kernel->yield('_sendTCP', $input);
    }
    else
    {
        die "Protocol $input->{'proto'} is not known. Can not deliver message for component\n";
    }

}

#
# internal used by 'send' event for sending the messages out
sub _sendTCP
{
    my ($self, $kernel, $input) = @_[ OBJECT, KERNEL, ARG0];    
    use POE::Component::Client::TCP;

    my ($serverHost, $serverPort) = ($input->{'host'}, $input->{'port'});

    $kernel->yield ('logger', "Sending message to $serverHost:$serverPort for the component", 'info');

    POE::Component::Client::TCP->new(
                                        RemoteAddress => $serverHost,
                                        RemotePort    => $serverPort,
                                        Filter        => "POE::Filter::Reference",
                                        ServerInput   => sub {}, # we do not expect to get anything from the server
                                        ObjectStates  => [ $self => [_connected => '_connected']],
                                        Connected     => sub { $_[KERNEL]->yield ('_connected', $input);},
                                        ConnectError => sub { 
                                                                my ($syscall, $errorNo, $error) = @_[ARG0, ARG1, ARG2];
                                                                $kernel->yield ('logger', "$syscall failed in attempt to connect to $serverHost:$serverPort. $error ($errorNo)");
                                                                die; 
                                                            },
                                        ServerError => sub {
                                                                my ($syscall, $errorNo, $error) = @_[ARG0, ARG1, ARG2];
                                                                $kernel->yield ('logger', "$syscall failed in thr connection to $serverHost:$serverPort. $error ($errorNo)");
                                                                die;
                                                           },

                                    );
}

sub _connected
{   
    my ($self, $output, $kernel, $heap) = @_[ OBJECT, ARG0, KERNEL, HEAP];
    $output->{info}->{agentProto} = 'tcp';
    $_[HEAP]->{server}->put ($output->{info});
    $kernel->yield ('logger', "Sending ". $output->{'info'}->{'command'} . " to server", 'info');
    $kernel->yield ('shutdown');
    #die "zzzz";
}


#
# internal event for waking the component up
sub _wakeUp
{

    my ($self, $kernel) = @_[OBJECT, KERNEL];
    

    my ($componentAlias, $wakeUpHandler );
    
    eval { ($componentAlias, $wakeUpHandler ) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getWakeUpHandler() ) };

    if ($@)
    {
        $kernel->yield('logger', 'The component does not need to be waken up.', 'info');
        return;
    }
   
    $kernel->yield('logger', 'Waking the component up.', 'info');
    $kernel->post ($componentAlias, $wakeUpHandler, $_[SESSION]);
}

sub logger
{
    my ($self, $msg) = @_[OBJECT, ARG0]; 
    my $logLevel = $_[ARG1] || "info";

#    print "log: $msg\n"
    
    Logger->log (  {
                     level => $logLevel, 
                     message => $msg."\n",
                   }
                );
}


"M";

