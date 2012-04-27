package Copilot::Security::Consumer;

=head1 NAME Copilot::Security::Consumer;

=head1 DESCRIPTION

This class implements the Consumer security module for the Copilot container classes. This module must be used by consumers (e.g. Copilot agents)
to obtain authentication ticket from the key server, authenticate response of providers (e.g. Storage Manager) and encrypt the communication between 
consumers and providers.

For general information about security modules please refer to  the documentation of Copilot::Security module. The module must be instantiated within 
one of the component containers (e.g. Copilot::Container::XMPP).  The following options must be provided during instantiation of the security module:

    'MODULE_NAME'                     => Name of the security module. Used as an alias to the POE session of the security module.

    'CONTAINER_ALIAS'                 => Alias of the container inside which the module is being instantiated.

    'SECURITY_OPTIONS'                => A hash reference with the options for the module. Possible options are:
                                            KMAddress               - Jabber ID of the key server
                                            TicketGettingCredential - A credential which must be presented to the key server in order to get authentication ticket
                                            PublicKeysFile    - A file which contains public keys of other components 
           
    'CONTAINER_LOG_HANDLER'           => Name of the event which handles message logging in the container

    'CONTAINER_DELIVER_INPUT_HANDLER' => Name of the event which handles input delivery to the component inside container

    'CONTAINER_SEND_HANDLER'          => Name of the event which handles output delivery to the component inside the container

Consumer module usage example:

    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'Agent',
                                                ...
                                                SecurityModule => 'Consumer',
                                                SecurityOptions => {
                                                                     KMAddress => $keyServerJID,
                                                                     TicketGettingCredential => 'blah', 
                                                                     PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                   },
                                            }
                                        );        

And here is how the module is instantiated within the container (e.g. Copilot::Container::XMPP)

    $self->{'SECURITY'} = $securityModule->new (
                                                {       
                                                    'MODULE_NAME' => $self->{'SECURITY_MODULE'},
                                                    'CONTAINER_ALIAS' => $self->{'MAIN_SESSION_ALIAS'},
                                                    'SECURITY_OPTIONS' => $options->{'SecurityOptions'},
                                                    'CONTAINER_LOG_HANDLER' => $self->{'LOG_HANDLER'},
                                                    'CONTAINER_DELIVER_INPUT_HANDLER' => $self->{'DELIVER_INPUT_HANDLER'},
                                                    'CONTAINER_SEND_HANDLER' => $self->{'SEND_HANDLER'},
                                                }                        
                                               );
   
=cut


use POE;

use vars qw (@ISA);

use MIME::Base64;

use Copilot::Security;
use Copilot::Util;
use Crypt::OpenSSL::RSA;

use strict;
use warnings;


use Data::Dumper;

@ISA = ("Copilot::Security");

sub _init
{
    my $self    = shift;
    my $options = shift;


    #
    # Read config 
    $self->_loadConfig($options);

    # Read public keys of components 
    $self->_loadPublicKeys ($options); 

    #
    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'MODULE_WAKEUP_HANDLER'} => \&moduleWakeUpHandler,
                                                $self->{'MODULE_PROCESS_INPUT_HANDLER'} =>  \&moduleInputHandler,
                                                $self->{'MODULE_PROCESS_OUTPUT_HANDLER'} =>  \&moduleOutputHandler,
                                                moduleProcessInput => \&moduleProcessInputHandler,
                                                moduleProcessOutput => \&moduleProcessOutputHandler,
                                                moduleGetTicket => \&moduleGetTicketHandler,
                                                moduleStoreTicket => \&moduleStoreTicketHandler,

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
    $self->{'MODULE_NAME'} = $options->{'MODULE_NAME'};
    
    # Server's session alias
    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
        or die "CONTAINER_ALIAS is not specified. Can't communicate with the container\n"; 

    # Event in server, which handles the messages sent from component to the outer world
     ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't send messages out. (Options -> CONTAINER_SEND_HANDLER )\n"; 

    # Event, which handles input inside the module
    $self->{'MODULE_PROCESS_INPUT_HANDLER'} = 'moduleInput';    
    
    # Event, which handles output inside the module
    $self->{'MODULE_PROCESS_OUTPUT_HANDLER'} = 'moduleOutput';    
    
    # Event, which handles wake up inside the module (called once, after container initialization is finished)
    $self->{'MODULE_WAKEUP_HANDLER'} = 'moduleHandleWakeUp';
            
    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger'); 

    # Key server address   
    $self->{'PUBLIC_KEYS'} = {};   
    
    ($self->{'KEY_SERVER'} = $options->{'SECURITY_OPTIONS'}->{'KMAddress'}) or ($self->{'KEY_SERVER'} = '');
    
    ($self->{'TICKET_GETTING_CREDENTIAL'} = $options->{'SECURITY_OPTIONS'}->{'TicketGettingCredential'})
        or ($self->{'TICKET_GETTING_CREDENTIAL'} = 'No credential'); 
    
    # Container's input and output deliveri handlers 
    ($self->{'DELIVER_INPUT_HANDLER'} = $options->{'CONTAINER_DELIVER_INPUT_HANDLER'}) 
        or die "Container's input delivery handle for security module is not specified (Options -> CONTAINER_DELIVER_INPUT_HANDLER)"; 
    

}

#
# Load public keys of the components
sub _loadPublicKeys
{
    my $self = shift;
    my $options = shift;
    
    my $keyFile;
    
    if ( defined ($options->{'SECURITY_OPTIONS'}->{'PublicKeysFile'})) 
    {
       $keyFile =  $options->{'SECURITY_OPTIONS'}->{'PublicKeysFile'}; 
    }
    else
    {
        warn "Warning: Public keys file is not given (SECURITY_OPTIONS -> PublicKeysFile)\n";
        return;
    }
    
    my $line;

    $self->{'PUBLIC_KEYS'} = {};

    open FH, "< $keyFile" or die "Can't open public keys file $keyFile: $!\n";
    
    while ($line = <FH>)
    {
        next unless $line =~ /\@/; 

        # found key entry for the component 
        chomp $line; 
        my $component = $line;
        my $key = "";
        do
        {
            $line = <FH>;            
            $key .= $line; 
        } while ($line !~ "-----END RSA PUBLIC KEY----");      
       
        $self->{'PUBLIC_KEYS'}->{$component} = {};      
        $self->{'PUBLIC_KEYS'}->{$component}->{'key'} = $key;    
    }    
    close FH;    
}

#
# Called before the session is destroyed
sub mainStopHandler
{
    #print "Stop has been called\n";
}

#
# Called before session starts 
sub mainStartHandler
{
    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;
   
    $kernel->alias_set ($self->{'MODULE_NAME'});

    #$_[SESSION]->option (trace => 1);
}

#
# Returns the name of wake up handler
sub getWakeUpHandler
{
    my $self = shift;
    return $self->{'MODULE_WAKEUP_HANDLER'}; 
}

#
# Returns the name of input handler 
sub getProcessInputHandler
{ 
    my $self = shift;
    return $self->{'MODULE_PROCESS_INPUT_HANDLER'}; 
}

#
# Returns the name of input handler 
sub getProcessOutputHandler
{ 
    my $self = shift;
    return $self->{'MODULE_PROCESS_OUTPUT_HANDLER'}; 
}

sub moduleWakeUpHandler
{
    my $kernel = $_[ KERNEL ];
    $kernel->yield ('moduleGetTicket');    
}

#
# Handles input data event from container
sub moduleInputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('moduleProcessInput', $input);
}

#
# Processes the input
sub moduleProcessInputHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $deliverInputHandler = $self->{'DELIVER_INPUT_HANDLER'};
    
    # make sure there were no security errors
    if (($input->{'from'} =~ /$self->{'KEY_SERVER'}/) and ref($input->{'body'}->{'info'}) eq 'HASH' and defined ($input->{'body'}->{'info'}->{'command'}))
    {
        my $cmd = $input->{'body'}->{'info'}->{'command'};
        if ($cmd eq 'security_error')
        {   
            my $errStr = $input->{'body'}->{'info'}->{'errorString'};
            $kernel->post ($container, $logHandler, "Got error from the key server: \"$errStr\"", 'error');             
            return;
        }
    }
   
    # 
    # get session key    
    my $sessionKey = $self->getSessionKey();     

    # Decode to get encrypted string 
    $input->{'body'}->{'info'} = decode_base64($input->{'body'}->{'info'});

    # Decrypt the string
    $input->{'body'}->{'info'} = $self->AESDecrypt($input->{'body'}->{'info'}, $sessionKey);

    # Decode decrypted string (now it contains the XML)
    $input->{'body'}->{'info'} = decode_base64($input->{'body'}->{'info'});
    
    # Convert an XML string to hash
    $input->{'body'}->{'info'} = Copilot::Util::XMLStringToHash ($input->{'body'}->{'info'});

    # Base64 decode the values of the hash
    $input->{'body'}->{'info'} = Copilot::Util::decodeBase64Hash($input->{'body'}->{'info'});   

    # Check if the message comes from the key server and in case it does, do not deliver the input to the client
    if (($input->{'from'} =~ /$self->{'KEY_SERVER'}/) and ($input->{'body'}->{'info'}->{'command'} eq "storeTicket"))
    {
        $kernel->yield('moduleStoreTicket', $input);
        return;
    }   
   
    $kernel->post ($container, $deliverInputHandler, $input);
}

#
# Handles output data event from container 
sub moduleOutputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('moduleProcessOutput', $input);
}


#
# Does input processing and dispatches the command (e.g. starts job) 
sub moduleProcessOutputHandler
{
    my ( $kernel, $heap, $output) = @_[ KERNEL, HEAP, ARG0];
    
    my $self = $heap->{'self'}; 
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};

    #
    # If this is not the message for requesting a ticket than we have to append a ticket to it
    my $to =  $output->{'to'}; 
    if (($to ne $self->{'KEY_SERVER'}) and ($output->{'info'}->{'command'} ne 'getTicket' ) )
    {
        # check if we have the ticket
        unless (defined ($self->{'COMPONENT_TICKET'}))
        {
            $kernel->post ($container, $logHandler, 'We do not have a ticket yet. Can not send the message to '.$to.' Retrying in 2 seconds.');
            $kernel->delay ('moduleProcessOutput', 2, $output);
            return;            
        }

        $output->{'info'}->{'componentAuthenticationTicket'} = $self->{'COMPONENT_TICKET'};
    }    
    
    #
    # get the session key 
    my $sessionKey = $self->getSessionKey();

    #
    # encrypt it with receiver's public key and put inside the output
    my $component = $output->{'to'};
    $output->{'session_key'} = $self->RSAEncryptWithComponentPublicKey ( encode_base64 ($sessionKey), $component);
    $output->{'session_key'} = encode_base64 ($output->{'session_key'});   
        
    #
    # Convert 'info' to XML and encrypt it with session key
    my $infoXMLString = Copilot::Util::hashToXMLNode($output->{'info'}, 'info')->to_str(); 
  
    #
    # encrypt the info with the session key     
    $output->{'info'} = encode_base64($self->AESEncrypt(encode_base64($infoXMLString), $sessionKey));   

    #print Dumper $output;

    $kernel->post ($container, $sendHandler, $output);
}


#
# Retrieves a ticket from key server
sub moduleGetTicketHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];

    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'}; 

    my $to = $self->{'KEY_SERVER'}; 

    if ($to)
    {
        my $ticketRequest = {
                            'to' => $to, 
                            'info' => {
                                        'command' => 'getTicket',
                                        'credential' => $self->{'TICKET_GETTING_CREDENTIAL'},
                                      },
                          };
        
        $kernel->yield ($logHandler, 'Sending request to '. $to . ' to get a ticket for the component');
        
        $kernel->yield ('moduleProcessOutput' , $ticketRequest);        
    }
    else 
    {
        $kernel->yield($logHandler, "The address of the key server is not defined. Not requesting a ticket.");
        $self->{'COMPONENT_TICKET'} = "No ticket";
    }
    
}


#
# Verifies and stores the ticket 
sub moduleStoreTicketHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'}; 

   
    my $data = $input->{'body'}->{'info'}->{'ticket'};
    my $component = $input->{'from'};
    
    # Strip out the XMPP resource string 
    ($component, undef) = split('/', $component);
    
    # verify the ticket
    my ($signature, $ticket) = split ('###', $data );
    my $verified = $self->RSAVerifySignatureWithComponentPublicKey($ticket, decode_base64($signature), $component);

    unless ($verified)
    {
        $kernel->post ($container, $logHandler, 'Failed to verify ticket signature from '.$component);
        die;
    }  
   
    #store the ticket
    $self->{'COMPONENT_TICKET'} = $data;    

    $kernel->post ($container, $logHandler, 'Ticket is received and signature is verified. Ticket is stored.');   
}
 
"M";
