package Copilot::Container::XMPP;

=pod

=head1 NAME Copilot::Container::XMPP

=head1 DESCRIPTION

Container class for an XMPP  client. Copilot::Container::XMPP is a child of Copilot::Container class. This class allows to communicate messages via XMPP protocol

Please also see the documentation of Copilot::Container

=cut

=head1 METHODS


=item new($options)

Constructor for Copilot::Container::XMPP class. Takes as an input hash reference with options. The following options can be specified:

    Component                   => Name of the component which must run in the container
    ComponentOptions            => Hash reference with options which must be passed to the component.
    JabberID                    => Jabber ID (username)
    JabberPassword              => Jabber password for authentication
    JabberDomain                => Jabber domain for which the ID is registered on the server
    JabberServer                => Jabber server hostname or IP
    JabberPort                  => Jabber server port (optional, default is 5222)
    MonitorAddress              => Jabber ID of the monitoring component
    ChatServer                  => Domain at which Jabber chat server is running (optional)
    ChatRoom                    => Chat room to which component should join after starting up (optional)
    UniqueMonitoringComponent   => '1' if data from this component should be separated from others in Graphites' interface
    Plugins                     => Hash with names of plugins that should be loaded and their options
    SecurityModule              => Name of the security module to use
    SecurityOptions             => Hash reference with the options which must be passed to the components

Example usage:

    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'JobManager',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ChatServer => $chatServer,
                                                ChatRoom => $chatRoom,
                                                MonitorAddress => $monitorAddress,
                                                UniqueMonitoringComponent => '1',
                                                ComponentOptions => {
                                                                     ChirpDir => $chirpWorkDir ,
                                                                     AliEnUser => 'hartem',
                                                                     StorageManagerAddress => $storageManagerJID,
                                                                    },
                                                Plugins => {
                                                            SystemMonitor => {},
                                                            Heartbeat     => {},
                                                           },
                                                SecurityModule => 'Provider',
                                                SecurityOptions => {
                                                                    KMAddress => $keyServerJID,
                                                                    PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                    ComponentPublicKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.pub',
                                                                    ComponentPrivateKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.priv',
                                                                   },
                                             }
                                        );

=cut





use strict;
use warnings;

use vars qw (@ISA);

use Copilot::Container;
use Copilot::Util;
use Copilot::GUID;

use POE;
use POE::Filter::Reference;
use POE::Component::Logger;

use POE::Component::Jabber;                   #include PCJ
use POE::Component::Jabber::Error;            #include error constants
use POE::Component::Jabber::Status;           #include status constants
use POE::Component::Jabber::ProtocolFactory;  #include connection type constants

use XML::SAX::Expat::Incremental; # explicit require (needed for rBuilder)

use MIME::Base64;

use Data::Dumper;

use Time::HiRes qw(time);


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

    my $debugOptions = {};
    $self->{'DEBUG'} && ($debugOptions = { debug => 1, trace => 1});

    #
    # Create main POE session here. It will serve as a bridge between POE::Component::Jabber and the component
    $self->{session} = POE::Session->create (
                                                options       => $debugOptions, #{ debug => 1, trace => 1},
                                                args          => [ $self ],
                                                inline_states => {
                                                                    _start                  => \&mainStartHandler,
                                                                    _stop                   => \&mainStopHandler,
                                                                    $self->{'LOG_HANDLER'}  => \&msgLogHandler,
                                                                    logstalgia              => \&msgLogstalgiaHandler,
                                                                    statusEvent             => \&pcjStatusEventHandler,
                                                                    errorEvent              => \&pcjErrorEventHandler,
                                                                    outputEvent             => \&pcjOutputEventHandler,
                                                                    inputEvent              => \&pcjInputEventHandler,
                                                                    reconnectEvent          => \&pcjReconnectEventHandler,
                                                                    componentWakeUp         => \&componentWakeUpHandler, # Event for waking the component up
                                                                    $self->{'DELIVER_INPUT_HANDLER'} => \&componentDeliverInputHandler, # Event for delivering input to the component
                                                                    $self->{'DELIVER_OUTPUT_HANDLER'} => \&componentDeliverOutputHandler, # Event for delivering output from the component
                                                                    $self->{'SEND_HANDLER'} => \&componentSendHandler, # Event for sending messages to the outer world
                                                                    componentSendDelayed    => \&componentSendDelayedHandler,
                                                                    componentSendAck        => \&componentSendAckHandler,
                                                                    processQueue            => \&mainProcessQueueHandler,
                                                                },

                                            );

    # Registering monitoring states if Monitor's JID was provided
    if ( defined ($self->{'MONITOR_ADDRESS'}) && $self->{'MONITOR_ADDRESS'} ne '' )
    {
        $self->{session}->_register_state ($self->{'MONITOR_HANDLER'},               \&monitorReportEventHandler);
        $self->{session}->_register_state ($self->{'MONITOR_VALUE_HANDLER'},         \&monitorReportEventValueHandler);
        $self->{session}->_register_state ($self->{'MONITOR_START_TIMING_HANDLER'},  \&monitorStartEventHandler);
        $self->{session}->_register_state ($self->{'MONITOR_STOP_TIMING_HANDLER'},   \&monitorStopEventHandler);
        $self->{session}->_register_state ($self->{'MONITOR_DETAILS_HANDLER'},       \&monitorStoreEventDetailsHandler);
        $self->{session}->_register_state ($self->{'MONITOR_UPDATE_DETAILS_HANDLER'},\&monitorUpdateEventDetailsHandler);

        eval 'use JSON;';
    }

    if ( defined ($self->{'CHAT_SERVER'}) && $self->{'CHAT_SERVER'} ne '' )
    {
        $self->{session}->_register_state ('joinChatRoom', \&componentJoinChatRoom);
    }

    # Instantiate the component
    my $component = "Copilot::Component::".$self->{COMPONENT_NAME};
    eval " require $component";
    if ($@)
    {
        die "Failed to load $component : $@ \n";
    }

    # options used to initialize both the component and the plugins
    my %initOptions = (
                        CONTAINER_ALIAS         => $self->{'MAIN_SESSION_ALIAS'},
                        CONTAINER_SEND_HANDLER  => $self->{'DELIVER_OUTPUT_HANDLER'},
                        SECURITY_OPTIONS        => $options->{'SecurityOptions'},
                        CONTAINER_LOG_HANDLER   => $self->{'LOG_HANDLER'},
                        MONITOR_HANDLER         => $self->{'MONITOR_HANDLER'},
                        MONITOR_VALUE_HANDLER   => $self->{'MONITOR_VALUE_HANDLER'},
                        TIMING_START_HANDLER    => $self->{'MONITOR_START_TIMING_HANDLER'},
                        TIMING_STOP_HANDLER     => $self->{'MONITOR_STOP_TIMING_HANDLER'},
                        MONITOR_DETAILS_HANDLER => $self->{'MONITOR_DETAILS_HANDLER'},
                        MONITOR_UPDATE_DETAILS_HANDLER => $self->{'MONITOR_UPDATE_DETAILS_HANDLER'},
                      );

    my %componentInitOptions = (%initOptions, COMPONENT_NAME    => $self->{'COMPONENT_NAME'},
                                              COMPONENT_OPTIONS => $options->{'ComponentOptions'},
                               );
    $self->{'COMPONENT'} = $component->new(\%componentInitOptions);

    # Instantiate plugins
    my $plugins = $options->{'Plugins'} || {};
    foreach my $pluginName (keys %$plugins)
    {
        my $plugin = 'Copilot::Plugin::' . $pluginName;
        eval "require $plugin";

        if ( $@ )
        {
            die "Failed to load $plugin: $@.\n";
        }

        my %pluginInitOptions = (%initOptions, PLUGIN_NAME    => $pluginName,
                                               PLUGIN_OPTIONS => $plugins->{$pluginName},
                                );
        $self->{'loadedPlugins'}->{$pluginName} = $plugin->new (\%pluginInitOptions);
    }

    # Instantiate the security module
    if (defined ($self->{'SECURITY_MODULE'}))
    {
        my $securityModule = "Copilot::Security::".$self->{'SECURITY_MODULE'};
        eval " require $securityModule";
        if ($@)
        {
            die "Failed to load security module $securityModule: $@\n";
        }

        $self->{'SECURITY'} = $securityModule->new (
                                                    {
                                                        'MODULE_NAME'                       => $self->{'SECURITY_MODULE'},
                                                        'CONTAINER_ALIAS'                   => $self->{'MAIN_SESSION_ALIAS'},
                                                        'CONTAINER_SEND_HANDLER'            => $self->{'SEND_HANDLER'},
                                                        'SECURITY_OPTIONS'                  => $options->{'SecurityOptions'},
                                                        'CONTAINER_LOG_HANDLER'             => $self->{'LOG_HANDLER'},
                                                        'CONTAINER_DELIVER_INPUT_HANDLER'   => $self->{'DELIVER_INPUT_HANDLER'},
#                                                       'CONTAINER_DELIVER_OUTPUT_HANDLER' => $self->{'DELIVER_OUTPUT_HANDLER'},
                                                    }
                                                   );
    }

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

    # Will be used as an alias for POE::Component::Jabber
    $self->{'MAIN_SESSION_ALIAS'} = "Container_".$self->{'COMPONENT_NAME'};

    # Event name which will be used to log messages
    $self->{'LOG_HANDLER'} = 'logger';

    # Event name which will be used to deliver input to the Component
    $self->{'DELIVER_INPUT_HANDLER'} = 'componentDeliverInput';

    # Event name which will be used to deliver input to the component
    $self->{'DELIVER_OUTPUT_HANDLER'} = 'componentDeliverOutput';

    # Event name which will be used in the component needs to send something
    # to the outer world.
    $self->{'SEND_HANDLER'} = 'componentSend';

    # Event name which sends the event data to Monitor component
    $self->{'MONITOR_HANDLER'} = 'monitorReportEvent';

    # Event name which sends the event data to Monitor component
    $self->{'MONITOR_VALUE_HANDLER'} = 'monitorReportEventValue';

    # Event name which starts internal timing
    $self->{'MONITOR_START_TIMING_HANDLER'} = 'monitorStartEvent';

    # Event name which stops internal timing and sends the data to Monitor
    $self->{'MONITOR_STOP_TIMING_HANDLER'} = 'monitorStopEvent';

    # Logger configuration file
    $self->{'LOGGER_CONFIG_FILE'} = $options->{'LoggerConfig'} || die "Logger configuration file not provided. Can not start the server.\n";

    # Jabber ID, password and hostname
    $self->{'JABBER_ID'}       = $options->{'JabberID'}     || die "Jabber ID (username) is not provided.\n";
    $self->{'JABBER_DOMAIN'}   = $options->{'JabberDomain'} || die "Jabber domain is not provided\n";
    $self->{'JABBER_PASSWORD'} = $options->{'JabberPassword'};
    $self->{'JABBER_RESOURCE'} = $options->{'JabberResource'};
    $self->{'JABBER_RESEND'}   = $options->{'JabberResend'};

    # Jabber server hostname (or IP) and port
    $self->{'JABBER_SERVER_ADDRESS'} = $options->{'JabberServer'} || die "Jabber server address is not provided";
    $self->{'JABBER_SERVER_PORT'}    = $options->{'JabberPort'}   || "5222";

    # Chat room and the chat server used by the Heartbeat plugin
    $self->{'CHAT_SERVER'} = $options->{'ChatServer'} || '';
    $self->{'CHAT_ROOM'}   = $options->{'ChatRoom'}   || '';

    # Jabber ID of the monitoring component
    $self->{'MONITOR_ADDRESS'} = $options->{'MonitorAddress'} || undef;
    if ( defined ($self->{'MONITOR_ADDRESS'}) )
    {
        # Name with which the data will be represented in Graphite
        my $mid = lc $self->{'COMPONENT_NAME'};
        $mid =~ s/::/\./g;
        my $uniqueComponent = $options->{'UniqueMonitoringComponent'} || '0';
        if ($uniqueComponent eq '1')
        {
            my $resource = $self->{'JABBER_RESOURCE'};
            $resource and ($mid .= '.' . $resource);
        }
        $self->{'MONITORING_ID'} = $mid;
    }

    # Security module name
    $self->{'SECURITY_MODULE'} = $options->{'SecurityModule'};

    $self->{'CONTAINER_CONNECTION'} = 0;

    # Debugging enabled
    $self->{'DEBUG'} = $options->{'Debug'} || "0";

    # Aggressive reconnect
    $self->{'ENABLE_AGGRESSIVE_RECONNECT'} = ($options->{'EnableAggressiveReconnect'} || undef);
}

#
# Start handler of the main POE session
sub mainStartHandler
{
    my ( $kernel, $heap, $self ) = @_[ KERNEL, HEAP, ARG0 ];

    $heap->{'self'} = $self;
    $kernel->alias_set($self->{'MAIN_SESSION_ALIAS'});

    my $debugOptions = '0';
    $self->{'DEBUG'} && ($debugOptions = '1');

    my $jabberOptions = {
                           IP               => $self->{'JABBER_SERVER_ADDRESS'},
                           Port             => $self->{'JABBER_SERVER_PORT'},
                           Username         => $self->{'JABBER_ID'},
                           Password         => $self->{'JABBER_PASSWORD'},
                           Hostname         => $self->{'JABBER_DOMAIN'},
                           Alias            => 'Jabber',
                           ConnectionType   => +XMPP, #+LEGACY ,
                           Debug            => $debugOptions, #'0',
                           States           => {
                                                StatusEvent => "statusEvent",
                                                InputEvent  => "inputEvent",
                                                ErrorEvent  => "errorEvent",
                                               },
                         };

   if (defined($self->{'JABBER_RESOURCE'}) && $self->{'JABBER_RESOURCE'} ne '')
   {
       $jabberOptions->{'Resource'} = $self->{'JABBER_RESOURCE'};
   }

   $heap->{'Jabber'} = POE::Component::Jabber->new( %$jabberOptions );

   $heap->{'GUID'} = new Copilot::GUID;
   $heap->{'MessageQueue'} = {};

   $kernel->delay ('reconnectEvent', 1);
   $kernel->delay ('componentWakeUp', 2);
   if (defined($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1')
   {
      $kernel->delay ('processQueue', 1);
   }
}

#
# Stop handler of the main POE session
sub mainStopHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};

#    $kernel->state('reconnectEvent');
#    delete $heap->{'Jabber'};
    $kernel->post('Jabber', 'shutdown');
    $kernel->post ('Jabber', '_stop');
    $kernel->alias_remove($self->{'MAIN_SESSION_ALIAS'});

    #$kernel->stop();
    #sleep 5 && exit 0;
}

sub pcjOutputEventHandler
{
    # This is our own output_event that is a simple passthrough on the way to
    # post()ing to PCJ's output_handler so it can then send the Node on to the
    # server
    my ( $kernel, $node, $sid ) =  @_[ KERNEL, HEAP, ARG0, ARG1 ];
    t d($node);
    $kernel->post( 'Jabber', 'output_handler', $node );
}

#
# Delivers output from component to the client
# Expects hash on input. Removes from hash 'from' and 'to' ('from' field is optional) fields, puts the rest of the elements to POE::Filter::XML::Node
# and sends it
sub componentDeliverOutputHandler
{
    my ($kernel, $heap, $output) = @_ [ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    if ($self->{'CONTAINER_CONNECTION'} == 0)
    {
        $kernel->yield ($self->{'LOG_HANDLER'}, 'Do not have a connection. Delivery of the message will be delayed.', 'warn');
    }

    my $handler = $self->{'SEND_HANDLER'};

    if (defined ($self->{'SECURITY'}))
    {
        my ($securityModule, $outputHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getProcessOutputHandler());
        $kernel->post ($securityModule, $outputHandler, $output);
    }
    else
    {
        $kernel->yield ($handler, $output);
    }
}

sub componentSendDelayedHandler
{
    my ($kernel, $node) = @_[KERNEL, ARG0];
    $kernel->post ('Jabber', 'output_handler', $node);
}

sub componentSendHandler
{
    my ( $kernel, $heap, $output ) = @_ [ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $from = $output->{'from'} || $self->{'JABBER_ID'}.'@'.$self->{'JABBER_DOMAIN'};
    delete ($output->{'from'});

    my $to   = $output->{'to'};
    delete ($output->{'to'});

    my $noack = $output->{'noack'} || '0';
    $noack and (delete ($output->{'noack'}));

    my $broadcast = $output->{'broadcast'} || '0';
    $broadcast and (delete ($output->{'broadcast'}));

    # Append an ID
    my $GUID = $heap->{'GUID'};
    my $id = $GUID->CreateGuid();


    my $node = POE::Filter::XML::Node->new('message');
    $node->attr('from', $from);
    $node->attr('to', $to);
    $node->attr('id', $id);
    $node->attr('noack', '1') if $noack eq '1';
    $node->attr('type', 'groupchat') if $broadcast eq '1';
    $node->insert_tag (Copilot::Util::hashToXMLNode ($output));

    if ( (defined($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1') && $noack eq '0')
    {
        my $command = $output->{'info'}->{'command'};

        if (defined($command))
        {
            if (defined($heap->{'commandQueue'}->{$command}))
            {
                $kernel->yield($self->{'LOG_HANDLER'}, "The queue already contains a $command message.", 'debug');
                return;
            }

            $heap->{'commandQueue'}->{$command} = 1;
        }

        # Enqueue the message
        $heap->{'messageQueue'}->{$id} = {};
        $heap->{'messageQueue'}->{$id}->{'node'} = $node;
        $heap->{'messageQueue'}->{$id}->{'timestamp'} = time() + 60; # The other end has a minute to reply
        $heap->{'messageQueue'}->{$id}->{'trial'} = 1;
        $heap->{'messageQueue'}->{$id}->{'command'} = $command if defined($command);
    }

    #$kernel->yield ($self->{'LOG_HANDLER'}, "Sending message to $to for the component (Msg ID:" . $id . ") MSG" . $node->to_str(), 'debug');
    $kernel->yield ($self->{'LOG_HANDLER'}, "Sending message to $to for the component (Msg ID:" . $id . ")", 'debug');
    $kernel->post ('Jabber', 'output_handler', $node);
}

#
#
sub mainProcessQueueHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $queue = $heap->{'messageQueue'};

    my $self = $heap->{'self'};

    my $now = time();

    foreach my $id (keys %$queue)
    {
        my $timestamp = $queue->{$id}->{'timestamp'};
        my $delta = $now - $timestamp;
        my $trial = $queue->{$id}->{'trial'};

        if ($delta > ($trial * 60)) # wait before resending
        {
            # Try to send again
            $queue->{$id}->{'trial'} *= 2;
            my $node = $queue->{$id}->{'node'};
            my $nodeHash = Copilot::Util::XMLNodeToHash($node);
            if ($self->{'CONTAINER_CONNECTION'} == 0)
            {
                $kernel->yield ($self->{'LOG_HANDLER'}, "We do not seem to have a Jabber connection. Trying to reconnect.", 'info');
                $kernel->post ('Jabber', 'reconnect');
            }
            else
            {
                $kernel->yield ($self->{'LOG_HANDLER'}, "Resending '" . $nodeHash->{'body'}->{'info'}->{'command'} . "' to ". $nodeHash->{'to'} . " (Msg ID: $id)", 'info');
                $kernel->post  ('Jabber', 'reconnect');
                $kernel->delay ('componentSendDelayed', 10, $node);
                $kernel->delay ('processQueue', 60);
                return;
            }
        }
    }

    $kernel->delay('processQueue', 10);
}

# This is the input event. We receive all data from the server through this
# event. ARG0 will be a POE::Filter::XML::Node object. XML Node will be converted
# to hash and will be passed to componentDeliverInput for delivery to the component.

sub pcjInputEventHandler
{

    my ( $kernel, $heap, $nodeXML ) = @_[ KERNEL, HEAP, ARG0 ];

    my $nodeType = $nodeXML->name();
    return if (($nodeType eq 'presence') or ($nodeType eq 'stream:stream'));

    my $nodeHash = Copilot::Util::XMLNodeToHash ($nodeXML);
    my $self = $heap->{'self'};

    my $from = $nodeHash->{'from'};

    # XMPP ping handler, usually sent by the MUC server
    if ($nodeType eq 'iq' and defined ($nodeHash->{'ping'}))
    {
        my $pong = POE::Filter::XML::Node->new('iq');
        $pong->attr('to',   $from);
        $pong->attr('from', $nodeHash->{'to'});
        $pong->attr('id',   $nodeHash->{'id'});
        $pong->attr('type', 'result');
        $kernel->post ('Jabber', 'output_handler', $pong);
        return;
    }

    if (defined ($self->{'SECURITY'}))
    {
        my ($securityModule, $inputHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getProcessInputHandler());
        $kernel->post ($securityModule, $inputHandler, $nodeHash) ;
    }
    else
    {
        my $handler =  $self->{'DELIVER_INPUT_HANDLER'};
        $kernel->yield ($handler, $nodeHash);
    }
}

sub componentSendAckHandler
{
    my ($kernel, $heap, $to, $from, $id) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

    my $self = $heap->{'self'};

    my $node = POE::Filter::XML::Node->new('message');
    $node->attr('from', $from);
    $node->attr('to', $to);
    $node->attr('ack', $id);

    $kernel->yield ($self->{'LOG_HANDLER'}, "Sending ACK message to $to (from $from) for the messages ID:" . $id . ")", 'debug');
    $kernel->post ('Jabber', 'output_handler', $node);
}


# Delvers input from client to the component
sub componentDeliverInputHandler
{
    my ($heap, $kernel, $sender, $input) = @_[ HEAP, KERNEL, SESSION, ARG0];
    my $self = $heap->{'self'};

    # Check if it is the error message
    my $error = $input->{'error'};
    my $noack = $input->{'noack'};

    if ((defined $error) && ($input->{'type'} eq 'error'))
    {
        if ( defined($error->{'service-unavailable'}) )
        {
            return if (defined $noack && $noack eq '1');
            my $from = $input->{'from'};
            $kernel->yield($self->{'LOG_HANDLER'}, "$from seems to be offline. Will retry.", 'warning');
            return;
        }
        else
        {
            my $errorDump = Dumper $error;
            $kernel->yield($self->{'LOG_HANDLER'}, 'Got an error message. Code: '. $error->{'code'}, 'warn');
            $kernel->yield($self->{'LOG_HANDLER'}, "Error message dump: $errorDump", 'debug');
            return;
        }
    }

    # Check if this is an ACK message
    my $ackId = $input->{'ack'};
    if (defined $ackId)
    {
        if (defined ($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1')
        {
            my $command = $heap->{'messageQueue'}->{$ackId}->{'command'};
            delete $heap->{'messageQueue'}->{$ackId};
            delete $heap->{'commandQueue'}->{$command} if defined ($command);
        }
        $kernel->yield($self->{'LOG_HANDLER'}, 'Got ACK for ' . $ackId, 'debug');
        return;
    }

    my $msgForComponent = $input->{'body'}->{'info'};
    if (ref ($msgForComponent) eq 'HASH')
    {
        $msgForComponent->{'from'} = $input->{'from'};
        $msgForComponent->{'to'} = $input->{'to'};

        # Send ack for this message
        my $id = $input->{'id'};
        if (defined $id)
        {
            my $to = $msgForComponent->{'from'};
            my $from = $msgForComponent->{'to'};

            # Make sure that we process messages only once
            if (defined($heap->{'processedMessagesQueue'}->{$id}) && $heap->{'processedMessagesQueue'}->{$id} > 3 )
            {
                $kernel->yield($self->{'LOG_HANDLER'}, "The message with ID: $id has already been processed. Ignoring", 'warn');
                $kernel->yield('componentSendAck', $to, $from, $id);
            }
            else
            {
                    if (defined($heap->{'processedMessagesQueue'}->{$id}))
                    {
                        ++$heap->{'processedMessagesQueue'}->{$id};
                    }
                    else
                    {
                        $heap->{'processedMessagesQueue'}->{$id} = 1;
                    }

                    $kernel->yield($self->{'LOG_HANDLER'}, "Got msg with ID: $id from " . $msgForComponent->{'from'}, 'debug');

                    unless (defined($noack) && $noack eq '1')
                    {
                        $kernel->yield('componentSendAck', $to, $from, $id);
                    }

                    my ($pluginName, $command) = split (':', $msgForComponent->{'command'});
                    if ( defined($pluginName) && defined($command) )
                    {
                        # Dispatch the input to a plugin (if it exists)
                        my $plugin = $self->{'loadedPlugins'}->{$pluginName};

                        if ( defined($plugin) )
                        {
                            $kernel->post ($pluginName, $plugin->getInputHandler(), $msgForComponent);
                        }
                        else
                        {
                            $kernel->yield ($self->{'LOG_HANDLER'}, "Got message for non-initialised plugin, '$pluginName'. Ignoring", 'warn');
                        }
                    }
                    else
                    {
                        # Dispatch the input message to the component
                        my ($componentAlias, $handler) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getInputHandler());
                        $kernel->post ($componentAlias, $handler, $msgForComponent);
                    }
            }
        }
        else
        {
            my $msgDump = Dumper $input;
            $kernel->yield($self->{'LOG_HANDLER'}, "Got the message without ID. Ignoring. $msgDump", 'debug');
        }
    }
    else
    {
        $kernel->yield($self->{'LOG_HANDLER'}, "Got malformed message:\n". Dumper $input , 'error');
    }
}


#
# Reconnect handler
sub pcjReconnectEventHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $kernel->post('Jabber','reconnect');

    #$kernel->delay ('joinChatRoom', 1);
}

# The status event receives all of the various bits of status from PCJ. PCJ
# sends out numerous statuses to inform the consumer of events of what it is
# currently doing (ie. connecting, negotiating TLS or SASL, etc). A list of
# these events can be found in PCJ::Status.
sub pcjStatusEventHandler
{
    my ( $kernel, $sender, $heap, $state ) =  @_[ KERNEL, SENDER, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    if ( $state == +PCJ_CONNECT or $state == +PCJ_CONNECTING)
    {
        $self->{'CONTAINER_CONNECTION'} = 0;
    }
    if ( $state == +PCJ_INIT_FINISHED )
    {
          $kernel->post( 'Jabber', 'output_handler', POE::Filter::XML::Node->new('presence') );
          $kernel->delay ('joinChatRoom', 1);

          # And here is the purge_queue. This is to make sure we haven't sent
          # nodes while something catastrophic has happened (like reconnecting).

          $kernel->post( 'Jabber', 'purge_queue' );
          $self->{'CONTAINER_CONNECTION'} = 1;
    }
}

# This is the error event. Any error conditions that arise from any point
# during connection or negotiation to any time during normal operation will be
# send to this event from PCJ. For a list of possible error events and exported
# constants, please see PCJ::Error
sub pcjErrorEventHandler
{
    my ( $kernel, $heap, $error ) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};
    $self->{'CONTAINER_CONNECTION'} = 0;

    if ( $error == +PCJ_SOCKETFAIL ) {
        my ( $call, $code, $err ) = @_[ ARG1 .. ARG3 ];
        $kernel->yield( $self->{'LOG_HANDLER'}, "Socket failed. Will try to reconnect.\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_SOCKETDISCONNECT ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Socket disconnected. Will try to reconnect.\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_CONNECTFAIL ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Connect failed. Will try to reconnect.\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_SSLFAIL ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Socket disconnected. Will try to reconnect\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_AUTHFAIL ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Failed to authenticate. Will try to reconnect\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_BINDFAIL ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Failed to bind to a resource. Will try to reconnect\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    elsif ( $error == +PCJ_SESSIONFAIL ) {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Failed to establish a session. Will try to reconnect\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
    else {
        $kernel->yield( $self->{'LOG_HANDLER'}, "Unkown error. Will try to reconnect\n", 'error');
        $kernel->delay( 'reconnectEvent', 3) if defined($self->{'ENABLE_AGGRESSIVE_RECONNECT'});
    }
}


#
# internal event for waking the component up
sub componentWakeUpHandler
{
    my ($heap, $kernel) = @_[HEAP, KERNEL];
    my $self = $heap->{'self'};

    # wake the component up
    my ($componentAlias, $wakeUpHandler );

    eval { ($componentAlias, $wakeUpHandler ) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getWakeUpHandler() ) };

    if ($@)
    {
        $kernel->yield($self->{'LOG_HANDLER'}, 'The component does not need to be waken up.', 'info');
    }
    else
    {
        $kernel->yield($self->{'LOG_HANDLER'}, 'Waking the component up.', 'info');
        $kernel->post ($componentAlias, $wakeUpHandler);
    }

    # wake the security module up
    my ($securityModuleAlias, $securityModuleWakeUpHandler);

    eval { ($securityModuleAlias, $securityModuleWakeUpHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getWakeUpHandler)};

    if ($@)
    {
        $kernel->yield ($self->{'LOG_HANDLER'}, 'The security module does not need to be waken up.');
        return;
    }

    $kernel->yield ($self->{'LOG_HANDLER'}, 'Wake the security module up.');
    $kernel->post ($securityModuleAlias, $securityModuleWakeUpHandler);
}

sub msgLogstalgiaHandler
{
    my ($heap, $from, $command, $resp, $size) = @_[HEAP, ARG0, ARG1, ARG2, ARG3];

    my $self = $heap->{'self'};

    unless (defined ($self->{'LOGSTALGIA'}))
    {
        open ( $self->{'LOGSTALGIA'}, ">>", "/tmp/logstalgia.log")
            or die "Could not open /tmp/logstalgia.log: $!";
    }

    my $fh = $self->{'LOGSTALGIA'};
    my  ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);

    my @months = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
    $mon = $months[$mon];
    $year += 1900;

    ($from, undef) = split (/@/, $from);
    my $id = $from;
    $id =~ s/agent-//g;

    print $fh "$from - - [$mday/$mon/$year:$hour:$min:$sec +0000] \"BLAH $command"."_$id BLAH\" $resp $size\n";
}

sub msgLogHandler
{
    my ($heap, $msg) = @_[HEAP, ARG0];
    my $self = $heap->{'self'};

    my $logLevel = $_[ARG1] || "info";


    Logger->log (  {
                     level => $logLevel,
                     message => $msg."\n",
                   }
                );
}

sub componentJoinChatRoom
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    my $GUID = $heap->{'GUID'};

    my $nick        = $GUID->CreateGuid();
    my $chatServer  = $self->{'CHAT_SERVER'};
    my $chatRoom    = $self->{'CHAT_ROOM'};
    my $to          = $chatRoom . '@' . $chatServer . '/' . $nick;
    my $from        = $self->{'JABBER_ID'}.'@'.$self->{'JABBER_DOMAIN'};

    my $node = POE::Filter::XML::Node->new('presence');
    $node->attr('from', $from);
    $node->attr('to',   $to);
    $node->attr('id',   $nick);

    my $xMuc = POE::Filter::XML::Node->new('x');
    $xMuc->attr('xmlns', 'http://jabber.org/protocol/muc');
    $node->insert_tag($xMuc);

    $kernel->post('Jabber', 'output_handler', $node);
    $kernel->yield($self->{'LOG_HANDLER'}, "Joining chat room '$chatRoom' at $chatServer.")
}


# sends the event data to the monitor
sub monitorReportEventHandler
{
    my ($kernel, $heap, $event, $value, $type) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    my $self = $heap->{'self'};

    my $container      = $self->{'MAIN_SESSION_ALIAS'};
    my $sendHandler    = $self->{'SEND_HANDLER'};
    my $componentName  = $self->{'MONITORING_ID'};
    my $monitorAddress = $self->{'MONITOR_ADDRESS'};

    $type ||= '';
    my $command = 'reportEvent' . (ucfirst $type);

    my $eventLog = {
                    'to'    => $monitorAddress,
                    'info'  => {
                                 'command'   => $command,
                                 'event'     => $event,
                                 'component' => $componentName,
                               },
                    'noack' => 1,
                   };

    if ( $command ne 'reportEvent' )
    {
        $eventLog->{'info'}->{$type} = $value;
    }

    $kernel->post($container, $sendHandler, $eventLog);
}

sub monitorReportEventValueHandler
{
    my ($kernel, $heap, $eventType, $value, $valueType) = @_[ KERNEL, HEAP, ARG0, ARG1, ARG2 ];

    $kernel->yield('monitorReportEvent', $eventType, $value, $valueType || 'value');
}

# Starts internal counter for given event
# Since it's possible for multiple events of the same type to be running at the same time, $eventId is needed.
sub monitorStartEventHandler
{
    my ($kernel, $heap, $eventType, $eventId) = @_[ KERNEL, HEAP, ARG0, ARG1];
    my $self = $heap->{'self'};

    $self->{'eventTimers'}->{$eventId} = time ();

    $kernel->yield('monitorReportEvent', $eventType . '.start');
}

sub monitorStopEventHandler
{
    my ($kernel, $heap, $eventType, $eventId) = @_[ KERNEL, HEAP, ARG0, ARG1];
    my $self = $heap->{'self'};

    my $startedAt = $self->{'eventTimers'}->{$eventId};
    my $duration = time () - $startedAt;

    $kernel->yield ('monitorReportEvent', $eventType, $duration, 'duration');
    $kernel->yield ('monitorReportEvent', $eventType . '.end');
}

sub monitorStoreEventDetailsHandler
{
    my ($kernel, $heap, $details) = @_[KERNEL, HEAP, ARG0];
    my $self = $heap->{'self'};

    my $container      = $self->{'MAIN_SESSION_ALIAS'};
    my $sendHandler    = $self->{'SEND_HANDLER'};
    my $monitorAddress = $self->{'MONITOR_ADDRESS'};

    $details = encode_json $details;

    my $eventDetails = {
                    'to'    => $monitorAddress,
                    'info'  => {
                                 'command'   => 'storeEventDetails',
                                 'details'   => $details,
                               },
                    'noack' => 1,
                   };

    $kernel->post($container, $sendHandler, $eventDetails);
}

sub monitorUpdateEventDetailsHandler
{
    my ($kernel, $heap, $session, $updates) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $self = $heap->{'self'};

    my $container      = $self->{'MAIN_SESSION_ALIAS'};
    my $sendHandler    = $self->{'SEND_HANDLER'};
    my $monitorAddress = $self->{'MONITOR_ADDRESS'};

    $updates = encode_json $updates;

    my $eventUpdates = {
                    'to'    => $monitorAddress,
                    'info'  => {
                                 'command'   => 'updateEventDetails',
                                 'session'   => $session,
                                 'updates'   => $updates,
                               },
                    'noack' => 1,
                   };

    $kernel->post($container, $sendHandler, $eventUpdates);
}

"M";
