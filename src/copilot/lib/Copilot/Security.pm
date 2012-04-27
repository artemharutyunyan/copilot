package Copilot::Security;

=head1 NAME Copilot::Security

=head1 DESCRIPTION

This is an abstract base class for security modules (Copilot::Security::Consumer), which must be instantiated within a container (e.g. Copilot::Container::XMPP)

Modules which use Copilot::Security as a parent must provide the following methods:


=item _init($options)

This function is called from the constructor. Module initialization as well as POE::Session creation 
must be done in this function.

=cut  

=item getProcessInputHandler()

Must return the name of the event which handles input data processing. Whenever the container gets something 
from outer world it will yield an event using the name which getProcessInputHandler() returned. 
The component must also implement a handler for the event and register it during creation of POE::Session. 
 
=cut 

=item getProcessOutputHandler() 

Must return the name of the event which handles output data processing. Whenever the container sends something 
to the outer world it will yield an event using the name which getProcessOutputHandler() returned. 
The component must also implement a handler for the event and register it during creation of POE::Session. 

=cut

=item getWakeUpHandler() OPTIONAL 

Must return the name of the event which wakes the module up. It is called after container initialization is done.

=cut


=head1 METHODS

=cut


use strict;

use Crypt::CBC;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::AES;
use MIME::Base64;

use Data::Dumper;

sub new
{
    my $proto   = shift;
    my $options = shift;

    my $class = ref($proto) || $proto;
    my $self = {};

    bless ($self, $class);


    $self->_init($options);   

    return $self;
}


=item getSessionKey()

Returns session key for symmetric encryption. 

=cut
sub getSessionKey
{
    my $self = shift;

    unless (defined( $self->{'SESSION_KEY'}))
    {
        $self->{'SESSION_KEY'} = Crypt::CBC->random_bytes (32);
    }

     return $self->{'SESSION_KEY'};    
}

=item getComponentPublicKey()

 Returns public key of the component (takes component JID as input)

=cut

sub getComponentPublicKey
{
    my $self = shift;
    my $component = shift;

    my $key = $self->{'PUBLIC_KEYS'}->{$component}->{'key'};

    
    if (defined ($key))
    {
        return $key;
    }
    else
    {
       die "Public key for '$component' was not found.\n";
    }    
}

=item RSAEncryptWithComponentKey()

Retrieves the public key of the component and encrypts the plaintext with it

=cut

sub RSAEncryptWithComponentPublicKey
{
    my $self = shift;

    my $plain = shift;
    my $component = shift;

    my $rsa = $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'};
    unless (defined ($rsa))
    {
        my $key = $self->getComponentPublicKey($component);
        $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'} = Crypt::OpenSSL::RSA->new_public_key ($key);
        $rsa = $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'}; 
    } 

    return $rsa->encrypt ($plain);
}

=item RSADecryptWithComponentPrivateKey

Gets the ciphertext and decrypts it using component's private key 


=cut

sub RSADecryptWithComponentPrivateKey
{
    my $self = shift;

    my $cipher = shift;

    my $key = $self->{'COMPONENT_KEYS'}->{'PRIVATE_KEY'};
    my $rsa = $self->{'COMPONENT_KEYS'}->{'RSA_PRIVATE_KEY'};
   
    unless (defined ($rsa))
    {
        $self->{'COMPONENT_KEYS'}->{'RSA_PRIVATE_KEY'} = Crypt::OpenSSL::RSA->new_private_key ($key); 
        $rsa = $self->{'COMPONENT_KEYS'}->{'RSA_PRIVATE_KEY'}; 
    }
    
    return $rsa->decrypt($cipher);
}

=item RSAVerifySignatureWithComponentPublicKey

Retrieves the public key of the Component and verifies the signature

=cut

sub RSAVerifySignatureWithComponentPublicKey
{
    my $self = shift;

    my $text = shift;
    my $signature = shift;
    my $component = shift;

    my $rsa = $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'};
    unless (defined ($rsa))
    {
        my $key = $self->getComponentPublicKey($component);
        $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'} = Crypt::OpenSSL::RSA->new_public_key ($key);
        $rsa = $self->{'PUBLIC_KEYS'}->{$component}->{'rsa'}; 
    } 

    return $rsa->verify ($text, $signature); 
}


=item AESEncrypt

Encrypts the input using AES 

=cut

sub AESEncrypt
{
    my $self = shift;

    my $plain = shift;
    my $key = shift;

    my $cipher = Crypt::CBC->new (
                                    -key =>  $key,
                                    -cipher => "Crypt::OpenSSL::AES",
                                 );

    return $cipher->encrypt($plain);
}

=item AESDecrypt

Decrypts the input using AES 

=cut

sub AESDecrypt
{
    my $self = shift;

    my $plain = shift;
    my $key = shift;

    my $cipher = Crypt::CBC->new (
                                    -key =>  $key,
                                    -cipher => "Crypt::OpenSSL::AES",
                                 );

    return $cipher->decrypt($plain);
}

"M";
