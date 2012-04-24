package Copilot::Component::ContextManager;

=head1 NAME Copilot::Component::ContextManager

=head1 DESCRIPTION

This class implements the Context Manager of the Copilot system for Generic. It is a child class of 
Copilot::Component (for general information about the components in Copilot please refer to Copilot::Component 
documentation). The component must be instantiated within one of the component containers 
(e.g. Copilot::Container::XMPP). The following options must be provided during 
instantiation via 'ComponentOptions' parameter:

    RedisServer - Address of the redis server which must be used by the Context Manager    
    RedisPort   - Port of the redis server 

    Exmaple of ContextManager instantiation:

    my $cm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'ContextManager',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ComponentOptions => {
                                                                    RedisServer => $redisServer, 
                                                                    RedisPort => $redisPort, 
                                                                  },
                                                SecurityModule => 'Provider',
                                                SecurityOptions => {
                                                                    KMAddress => $keyServerJID,
                                                                    PublicKeysFile => $pub,
                                                                    ComponentPublicKey => $componentPub,
                                                                    ComponentPrivateKey => $componentPriv,
                                                                   },                 
                                            }
                                        ); 
=cut


use strict;
use warnings;

use vars qw (@ISA);
our $VERSION="0.01";

use Copilot::Component;


use POE;
use POE::Component::Logger;

use Data::Dumper;

use Redis;
use Digest::SHA1 qw (sha1_hex);

@ISA = ("Copilot::Component");

sub _init
{
    my $self    = shift;
    my $options = shift;


    #
    # Read config 
    $self->_loadConfig($options);

    #
    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'COMPONENT_INPUT_HANDLER'} => \&componentInputHandler,
                                                componentProcessInput              => \&componentProcessInputHandler,
                                                componentGetContext                => \&componentGetContextHandler,
                                                componentNoContext                 => \&componentNoContextHandler,
                                                componentSendContext               => \&componentSendContextHandler,
                                             },
                                     args => [ $self ],
                         ); 



    return $self;
}

#
# Loads config parameters into $self
sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    # Will be used an alias for this component
    $self->{'COMPONENT_NAME'} = $options->{'COMPONENT_NAME'};
    
    # Server's session alias
    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
        or die "CONTAINER_ALIAS is not specified. Can't communicate with server\n";
   
    # Event, which handles server input inside the component
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentHandleInput';    

    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger'); 

    # Event in server, which handles the messages sent from component to the outer world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n"; 

    #redis
    $self->{'REDIS_HOST'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisServer'} || 
        die "Redis server address is not provided\n");

    $self->{'REDIS_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisPort'} || 
        die "Redis port address is not provided\n");
    
    $self->{'DEBUG'} = ($options->{'COMPONENT_OPTIONS'}->{'Debug'} || '0');
}

#
# Called before the session is destroyed
sub mainStopHandler
{
    print "Stop has been called\n";
}

#
# Called before session starts 
sub mainStartHandler
{

    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;
   
    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    $self->{'DEBUG'} && $_[SESSION]->option(trace => 1);
}


#
# Returns the name of input handler 
sub getInputHandler
{ 
    my $self = shift;
    return $self->{'COMPONENT_INPUT_HANDLER'}; 
}

#
# Handles input from server 
sub componentInputHandler
{
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0 ];
    
    my $self = $heap->{'self'};

    my $logHandler = $self->{'LOG_HANDLER'};
    my $container = $self->{'CONTAINER_ALIAS'};

    $kernel->yield ('componentProcessInput', $input);
}

#
# Does input processing and dispatches the command 
sub componentProcessInputHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $self->{'DEBUG'} && $kernel->post($container, $logHandler, Dumper $input);

    if ($input->{'command'} eq 'getContext')
    {
        $kernel->yield ('componentGetContext', $input);
        $kernel->post ($container, $logHandler, 'Got the context request');
    }
}

#
# Internal function which tries to retrieve a context from the database
sub componentGetContextHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $kernel->post ($container, $logHandler, 'Got context request from '. $input->{'from'}); 

    my $r = Redis->new(server=> $self->{'REDIS_HOST'}.":".$self->{'REDIS_PORT'});

    my $id = $input->{'contextID'};
    my $key = $input->{'contextKey'};

    my $context = $r->get('copilot:context_manager:context:'.$id.':data');

    my $verified = (sha1_hex ($context) eq $key);

    if (!$verified) # Verification failed 
    {
        $kernel->post($container, $logHandler, 'Could not verify the access key ( '. $key .') for the requested context (ID: '. $id .' )');
        $kernel->yield('componentNoContext', $input);  
    }
    elsif ( $context ) # Verification succeeded and context was found
    {
        $kernel->post ($container, $logHandler, 'Sending context with ID '. $input->{'contextID'}); 
        $kernel->yield ('componentSendContext', $input, $context);       
    }
    else # Veridication succedded but context was not found 
    {
        $kernel->post ($container, $logHandler, 'Could not find the requested context (ID: '.$id.' )');
        $kernel->yield('componentNoContext', $input);
    }
}

#
# Internal function for error reporting 
sub componentErrorHandler
{

}

#
# Internal function for reporting that context with a given guid has not been found
sub componentNoContextHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    $kernel->post($container, $logHandler, 'Returning noContext for the requested context (ID: '. $input->{'contextID'}. ' )', 'warn');  

    my $context = {
                     'to'   => $input->{'from'},
                     'info' => { 
                                'command'   => 'noContext',
                                'contextID' => $input->{'contextID'},
                               },                              
                  };

    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($context->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Sending \'noContext\' (ID:'.$input->{'contextID'},') to '.$input->{'from'});
    $kernel->post ($container, $sendHandler, $context);         
}

#
# Internal function for sending context to the requesters 
sub componentSendContextHandler
{
    my ($heap, $kernel, $input, $context) = @_[ HEAP, KERNEL, ARG0, ARG1 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};
   
    # Send the context to the agent
    my $toSend = {
                   'to'   => $input->{'from'},
                   'info' => { 
                               'command'   => 'applyContext',
                               'contextID' => $input->{'contextID'},
                               'context'   => $context,
                             },
                                   
                };

    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($toSend->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Sending context with ID '. $input->{'contextID'} .' to '.$input->{'from'});
    $kernel->post ($container, $sendHandler, $toSend);    
}

"M";
