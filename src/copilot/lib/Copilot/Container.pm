package Copilot::Container;

=head1 NAME Copilot::Containter 

This is a base class for a component container classes (e.g. Copilot::Container::XMPP)

The container instantiates the object of the class which must run inside it and communicates with it using POE events. During the instantiation 
the container passes to the component a hash reference with the followig options:

    'COMPONENT_NAME'           - Component must use this as the alias of its POE::Session (container uses this name to send events to the component)
    'CONTAINER_ALIAS'          - Alias of the container, which can be used by the component to send events to the container  
    'CONTAINER_SEND_HANDLER'   - Name of the event in the container which allows component to initiate connections and send data. 
                    
                              Example usage for XMPP:

                              $output = {
                                            to   => 'jm@cvmappi21.cern.ch', # Jabber ID of the component 
                                            info => {
                                                        command => 'getJob',
                                                    }, # the data which must be sent
                                        };
                              $kernel->post ($containerAlias, $containerSendHandler, $output);
                              
    'COMPONENT_OPTIONS'       - Hash reference which contains options which were specified during Copilot::Container::* object construction. Can be used to pass 
                              different options to the component.
    
    'SECURITY_OPTIONS'      - Hash reference which contains options which were specified during Copilot::Container::* object construction. Can be used to pass
                              different options to the security module.                              

    'CONTAINER_LOG_HANDLER' - Name of the event in the container which handles logging. 

                              Example usage:

                              $logMessage = 'We are alive';
                              $logLevel   = 'debug';    

                              # log debug message 
                              $kernel->post ($containerAlias, $containerLogHandler, $logMessage, $logLevel);

                              Note. Log level is optional. If not specified 'info' level will be used
                              
                              # log info message
                              $kernel->post ($containerAlias, $containerLogHandler, $logMessage);
                                 

Components which are needed to be run inside the container must implement the following methods:
    
    getInputHandler() - Must return the name of the event which handles component input. Whenever the container gets something 
    from outer world it will yield an event using the name which getInputHandler() returned. 
    The component must also implement a handler for the event and register it during creation of POE::Session. 
    
    OPTIONAL:

    getWakeUpHandler() - Must return the name of the event which handles the 'wake up' event. The component can implement this method 
    in case it needs to do something (e.g. initialization) upon the start.  
    The component must also implement a handler for the event and register it during creation of POE::Session.

=head1 METHODS

=cut

use vars qw (@ISA);

=item new ($options)

Constructor for Copilot::Container object. Takes as an input hash reference with options. The constructor 
creates the object of the needed class (e.g. Copilot::Container::XMPP) and calls its _init() function with 
$options as an argument. Example usage and options are documented in child classes 
(e.g. Copilot::Container::XMPP)


=cut

sub new
{
    my $proto   = shift;
    my $options = shift;


    my $class = ref($proto) || $proto;
    my $self = {};

    bless ($self, $class);

    #
    # call init function which will create the component 
    
    $self->_init($options); 

    return $self;
}

"M";
