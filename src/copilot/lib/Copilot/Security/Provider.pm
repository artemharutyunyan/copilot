package Copilot::Security::Provider;

=head1 NAME Copilot::Security::Provider;

=head1 DESCRIPTION

This class implements the Provider security module for the Copilot container classes. This module must be used by providers (e.g. Job Manager, Storage 
Manager) to authenticate requests from consumer (e.g. Copilot agents) and encrypt the communication between providers and consumers.

For general information about security modules please refer to  the documentation of Copilot::Security module. The module must be instantiated within 
one of the containers (e.g. Copilot::Container::XMPP).  The following options must be provided during instantiation of the security module:

    'MODULE_NAME'                     => Name of the security module. Used as an alias to the POE session of the security module.

    'CONTAINER_ALIAS'                 => Alias of the container inside which the module is being instantiated.

    'SECURITY_OPTIONS'                => A hash reference with the options for the module. Possible options are:
                                            KMAddress         - Jabber ID of the key server
                                            PublicKeysFile    - A file which contains public keys of other components 
                                            ComponentPublicKey  - A file which contains the public key of the component which is being instantiated
                                            ComponentPrivateKey - A file which contains the private key of the component which is being instantiated
            
    'CONTAINER_LOG_HANDLER'           => Name of the event which handles message logging in the container

    'CONTAINER_DELIVER_INPUT_HANDLER' => Name of the event which handles input delivery to the component inside container

    'CONTAINER_SEND_HANDLER'          => Name of the event which handles output delivery to the component inside the container

Provider module usage example:

    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'JobManager',
                                                ...
                                                SecurityModule => 'Provider',
                                                SecurityOptions => {
                                                                        KMAddress => $keyServerJID,
                                                                        PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                        ComponentPublicKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.pub', 
                                                                        ComponentPrivateKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.priv',
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
use Time::Local;

use Copilot::Security;
use Copilot::Util;

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

    # Read public keys of other components
    $self->_loadPublicKeys ($options); 

    #
    # Read public and private key of the components
    $self->_loadComponentKeyPair($options);  

    #
    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'MODULE_PROCESS_INPUT_HANDLER'} =>  \&moduleInputHandler,
                                                $self->{'MODULE_PROCESS_OUTPUT_HANDLER'} =>  \&moduleOutputHandler,
                                                moduleProcessInput => \&moduleProcessInputHandler,
                                                moduleVerifyTicket => \&moduleVerifyTicketHandler,
                                                moduleSendTicketVerificationError => \&moduleSendTicketVerificationErrorHandler,
                                                moduleProcessOutput => \&moduleProcessOutputHandler,
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

    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger'); 

    # Key server address   
    $self->{'PUBLIC_KEYS'} = {};   
   
    $self->{'VERIFY_TICKET'} = 1; 
    ($self->{'KEY_SERVER'} = $options->{'SECURITY_OPTIONS'}->{'KMAddress'}) or ($self->{'VERIFY_TICKET'} = 0);

    # Container's input and output deliveri handlers 
    ($self->{'DELIVER_INPUT_HANDLER'} = $options->{'CONTAINER_DELIVER_INPUT_HANDLER'}) 
        or die "Container's input delivery handle for security module is not specified (Options -> CONTAINER_DELIVER_INPUT_HANDLER)"; 
    
#    ($self->{'DELIVER_OUTPUT_HANDLER'} = $options->{'CONTAINER_DELIVER_OUTPUT_HANDLER'}) 
#        or die "Container's input delivery handle for security module is not specified (Options -> CONTAINER_DELIVER_INPUT_HANDLER)"; 

}

#
# Load public keys of the component
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

sub _loadComponentKeyPair
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
   
    $kernel->alias_set ($self->{'MODULE_NAME'});

    #$_[SESSION]->option (trace => 1);
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

#
# Handles input data event from container
sub moduleInputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('moduleProcessInput', $input);
}

#
# Does input processing and if needed passes the input to ticket verification function 
sub moduleProcessInputHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $sessionKey;
    # decrypt the session key
    eval 
    {
        $sessionKey = decode_base64 ($input->{'body'}->{'session_key'});
        $sessionKey = decode_base64($self->RSADecryptWithComponentPrivateKey ($sessionKey));
    };
    if ($@)
    {
        $kernel->post ($container, $logHandler, 'Could not decrypt the session key from '.$input->{'from'}. '. Got error: "'. $@.'"');
        my $output = {};
        $output->{'to'} = $input->{'from'};
        $output->{'info'}->{'command'} = 'security_error';
        $output->{'info'}->{'errorString'} = "Could not decrypt the session key";
        $kernel->post($container, $sendHandler, $output);
        return;   
    } 
  
    # decrypt the data using session key
    eval 
    {
        $input->{'body'}->{'info'} = $self->AESDecrypt (decode_base64($input->{'body'}->{'info'}), $sessionKey);
        $input->{'body'}->{'info'} = decode_base64 ($input->{'body'}->{'info'}); 
    };
    if ($@)
    {
        $kernel->post ($container, $logHandler, 'Could not decrypt the message from '.$input->{'from'}. '. Got error: "'. $@.'"');
        my $output = {};
        $output->{'to'} = $input->{'from'};
        $output->{'info'}->{'command'} = 'security_error';
        $output->{'info'}->{'errorString'} = "Could not decrypt the message";
        $kernel->post($container, $sendHandler, $output);
        return;   
    } 
    
    # convert the data from XML to hash
    my $info = Copilot::Util::XMLStringToHash ($input->{'body'}->{'info'}); 

    # decode base64 values of the hash
    $info = Copilot::Util::decodeBase64Hash($info);
  
    $input->{'body'}->{'info'} = $info;    
    
    # put the session key to the output hash
    $input->{'body'}->{'info'}->{'send_back'} = {};
    $input->{'body'}->{'info'}->{'send_back'}->{'session_key'} = $sessionKey; 

    # pass to ticket verification function or deliver the message directly
    if ($self->{'VERIFY_TICKET'})
    {
        $kernel->yield ('moduleVerifyTicket', $input);    
    }
    else
    { 
        my $deliverInputHandler = $self->{'DELIVER_INPUT_HANDLER'};        
        $kernel->post ($container, $deliverInputHandler, $input);
    }
}

#
# Verifies the ticket and in case of success passes the command to the component
sub moduleVerifyTicketHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    my $deliverInputHandler = $self->{'DELIVER_INPUT_HANDLER'};        
    my $logHandler = $self->{'LOG_HANDLER'};

    my $to = $input->{'to'};        
    
    # check and do no verification here in case we are inside getTicket procedure
    if (($to eq $self->{'KEY_SERVER'}) and ($input->{'body'}->{'info'}->{'command'} eq 'getTicket') )
    {
        $kernel->post ($container, $deliverInputHandler, $input);       
        return;
    }
    
    my $ticketString = $input->{'body'}->{'info'}->{'componentAuthenticationTicket'};
    delete ($input->{'body'}->{'info'}->{'componentAuthenticationTicket'}); 

    
    # verify ticket signature    
    my ($signature, $ticket) = split ('###', $ticketString );    
    my $verified = $self->RSAVerifySignatureWithComponentPublicKey($ticket, decode_base64($signature), $self->{'KEY_SERVER'});  
    
    unless ($verified)
    {
        $kernel->yield ('moduleSendTicketVerificationError', $input, 'Failed to verify ticket signature');
        return;
    }    
        
    $ticket = decode_base64($ticket);

    # verify ticket data
    my ($component, $validFrom, $validTo, $requester) = split ('###', $ticket);

    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime();     
    my $now = timegm($sec,$min,$hour,$mday,$mon,$year ); # epoch time (GMT)   

    # verify the component to which it can be used for authentication        
    if ( $component ne '*')
    { 
        $kernel->yield ('moduleSendTicketVerificationError', $input, 'The ticket is not valid for this component');
        return;
    }
    # verify validity time
    elsif ( $validFrom > $now)
    {
        $kernel->yield ('moduleSendTicketVerificationError', $input, 'The ticket is not yet valid (now is '.$now.' and the ticket is valid from '.$validFrom.')');
        return;
    }
    elsif ( $validTo < $now)
    {
        $kernel->yield ('moduleSendTicketVerificationError', $input, 'The ticket has expired (now is '.$now.' and the ticket is valid to '.$validTo.')');
        return;
    }
   
    
    # pass it to the component
    $kernel->post ($container, $logHandler, 'The ticket from '.$input->{'from'}.' was successfully verified');
    $kernel->post ($container, $deliverInputHandler, $input);
}
#
# Sends the error in case ticket verification has failed
sub moduleSendTicketVerificationErrorHandler
{
    my ( $kernel, $heap, $input, $errorString) = @_[ KERNEL, HEAP, ARG0, ARG1];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
 
    my $output = {};
    $output->{'to'} = $input->{'from'};
    $output->{'info'}->{'command'} = 'error';
    $output->{'info'}->{'errorString'} = $errorString;
    $output->{'send_back'}->{'session_key'} = $input->{'body'}->{'info'}->{'send_back'}->{'session_key'}; 

    $kernel->post ($container, $logHandler, 'Failed to authenticate ticket from '.$input->{'from'}. ' Sending "'. $errorString.'"');

    $kernel->yield ('moduleProcessOutput',$output);
}

#
# Handles output data event from container 
sub moduleOutputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('moduleProcessOutput', $input);

    
}


#
# Does the output processing
sub moduleProcessOutputHandler
{
    my ( $kernel, $heap, $output) = @_[ KERNEL, HEAP, ARG0];
    
    my $self = $heap->{'self'}; 
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
    my $logHandler = $self->{'LOG_HANDLER'};
    
    # get the session key 
    my $sessionKey = $output->{'send_back'}->{'session_key'}; 
    delete ($output->{'send_back'});
    unless ($sessionKey)
    {
       $kernel->post($container, $logHandler, "Error: Did not get session key in moduleProcessOutputHandler.\n");
       return;
    }
   
    # Convert 'info' to XML and encrypt it with session key
    my $infoXMLString = Copilot::Util::hashToXMLNode($output->{'info'}, 'info')->to_str(); 
  
    #
    # encrypt the info with the session key     
    $output->{'info'} = encode_base64($self->AESEncrypt(encode_base64($infoXMLString), $sessionKey));    
   
    $kernel->post ($container, $sendHandler, $output);
}
 
"M";
