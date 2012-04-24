package Copilot::Component::KeyManager;

=head1 NAME Copilot::Component::KeyManager

=head1 DESCRIPTION

This class implements the key manager component for the copilot system. It is a child class of Copilot::Component (for general information 
about the Components of Copilot please refer to Copilot::Component documentation). The component must be instantiated within one of 
the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during 
instantiation via 'ComponentOptions' parameter:

    TicketValidity - Issued ticket validity time (in seconds)

    Example of KeyManager instantiation:

    my $km = new Copilot::Container::XMPP (
                                            {
                                                Component => 'KeyManager',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ComponentOptions => {
                                                                    TicketValidity => 3600 * 24, # default ticket validity in seconds
                                                                  },
                                                SecurityModule => 'Provider',        
                                                SecurityOptions => {
                                                                        KMAddress => $jabberID.'@'.$jabberServer,
                                                                        PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                        ComponentPublicKey => '/home/hartem/copilot/copilot/etc/keys/ks_key.pub', 
                                                                        ComponentPrivateKey => '/home/hartem/copilot/copilot/etc/keys/ks_key.priv', 
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
use MIME::Base64;

use Crypt::OpenSSL::RSA;

use Time::Local;

@ISA = ("Copilot::Component");

sub _init
{
    my $self    = shift;
    my $options = shift;


    #
    # Read config 
    $self->_loadConfig($options);

    #
    # Read keys
    $self->_loadComponentKeypair($options);        
    
    #
    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'COMPONENT_INPUT_HANDLER'} => \&componentInputHandler,
                                                componentProcessInput => \&componentProcessInputHandler,
                                                componentAuthenticateTicketRequest => \&componentAuthenticateTicketRequestHandler,
                                                componentGetTicket => \&componentGetTicketHandler,
                                                    authenticateTicketRequest => \&authenticateTicketRequestHandler,
                                                    returnTicket => \&returnTicketHandler,
                                                    returnAuthenticationError => \&returnAuthenticationErrorHandler,
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

    $self->{'TICKET_VALIDITY'} = $options->{'COMPONENT_OPTIONS'}->{'TicketValidity'};
    $self->{'TICKET_VALIDITY'} or ($self->{'TICKET_VALIDITY'} = 3600*24); 
     
}

#
# Loads RSA keypair of the component 
sub _loadComponentKeypair
{
    my $self = shift;
    my $options = shift;

    my $pubKey = $options->{'SECURITY_OPTIONS'}->{'ComponentPublicKey'};
    my $privKey = $options->{'SECURITY_OPTIONS'}->{'ComponentPrivateKey'}; 
   
    unless (defined($pubKey) and defined ($privKey))
    {
        warn "Warning: Public and/or Private key of the component is not given (SECURITY_OPRIONS -> ComponentPublicKey and SECURITY_OPTIONS -> ComponentPrivateKey )\n";     
        return; 
    }

    $self->{'COMPONENT_KEYS'} = {};
    
    open PUB, "< $pubKey" or die "Can not open public key file $pubKey: $!\n";
    $self->{'COMPONENT_KEYS'}->{'PUBLIC_KEY'} = join ('', <PUB>); 
    close PUB;

    open PRIV, "< $privKey" or die "Can not open private key file $privKey: $!\n";
    $self->{'COMPONENT_KEYS'}->{'PRIVATE_KEY'} = join ('', <PRIV>);
    chomp $self->{'COMPONENT_KEYS'}->{'PRIVATE_KEY'}; 
    close PRIV;

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
    $heap->{'jobs'} = {};
    
    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    # Initialize RSA   
    $heap->{'self'}->{'COMPONENT_KEYS'}->{'RSA_PUBLIC_KEY'}  = Crypt::OpenSSL::RSA->new_public_key  ($self->{'COMPONENT_KEYS'}->{'PUBLIC_KEY'}); 
    $heap->{'self'}->{'COMPONENT_KEYS'}->{'RSA_PRIVATE_KEY'} = Crypt::OpenSSL::RSA->new_private_key ($self->{'COMPONENT_KEYS'}->{'PRIVATE_KEY'});    
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
   my ($kernel, $input) = @_[KERNEL, ARG0 ];
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
    my $from = $input->{'from'};

    if ($input->{'command'} eq 'getTicket')
    {
        $kernel->post ($container, $logHandler, 'Agent (ID: '. $from .') has requested a ticket');    
        $kernel->yield ('componentGetTicket', $input);
    }
    else
    {
         $kernel->post ($container, $logHandler, 'Got unkown command from '. $from .'. The dump of the input is '. Dumper $input);          
    }

}

#
# Returns a ticket for accessing the component
sub componentGetTicketHandler
{
    my ( $heap, $kernel, $input ) = @_[ HEAP, KERNEL, ARG0 ];

    $kernel->yield ('authenticateTicketRequest', $input);
}

#
# Authenticates the ticket request 
sub authenticateTicketRequestHandler
{
    my ( $heap, $kernel, $input ) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};
   
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};
   
    my $from = $input->{'from'};
    
    my $authenticated = 1;  
    
    if ($authenticated)
    {
        $kernel->post ($logHandler, 'Successfully authenticated ticket request from: ', $from);
        $kernel->yield ('returnTicket', $input);
    }
    else 
    {
        $kernel->post ($logHandler, 'Failed to authenticate ticket request from: ', $from);
        $kernel->yield ('returnAuthenticationError', $input);
    }                                  
}

#
# Returns a ticket 
sub returnTicketHandler
{
    my ( $heap, $kernel, $input ) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};
   
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $from = $input->{'from'};
    
    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime();
       
    my $validFrom = timegm($sec,$min,$hour,$mday,$mon,$year ); # epoch time (GMT)
    my $validTo = $validFrom + $self->{'TICKET_VALIDITY'}; # now + 24 hours      
    
    my $ticketString = encode_base64 ('*'.'###'.$validFrom.'###'.$validTo.'###'.$from);
    my $signature = encode_base64 ($self->{'COMPONENT_KEYS'}->{'RSA_PRIVATE_KEY'}->sign ($ticketString));
    
    my $ticket = {};
    $ticket->{'to'} = $from;
    $ticket->{'info'} = {
                            'command' => 'storeTicket',
                            'ticket' => $signature.'###'.$ticketString,
                        };

    defined ($input->{'send_back'}) and ($ticket->{'send_back'} =  $input->{'send_back'});
    
    $kernel->post ($container, $logHandler, 'Sending ticket to: '.$from );
    $kernel->post ($container, $sendHandler, $ticket);    
}

sub returnAuthenticationErrorHandler
{
    my ( $heap, $kernel, $input ) = @_[ HEAP, KERNEL, ARG0 ];
   
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};
   
    my $from = $input->{'from'};
    
    my $ticket = {};
    $ticket->{'from'} = $from;
    $ticket->{'info'} = {
                            'command' => 'errorGetTicket',
                        };    
 
    $kernel->post ($container, $logHandler, 'Failed to authenticate ticket request from '.$from );
    $kernel->post ($container, $sendHandler, $ticket);    
}

"M";
