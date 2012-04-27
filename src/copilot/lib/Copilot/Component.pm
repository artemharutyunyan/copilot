package Copilot::Component;

=head1 NAME Copilot::Component

=head1 DESCRIPTION

This is a base class for components (e.g. Copilot::Component::Agent), which must be instantiated within a container (e.g. Copilot::Container::XMPP)

Component which uses Copilot::Component as a parent must provide the following methods:


=item _init($options)

This function is called from the constructor. Component initialization as well as POE::Session creation 
must be done in this function.

=cut  

=item getInputHandler()

Must return the name of the event which handles component input. Whenever the container gets something 
from outer world it will yield an event using the name which getInputHandler() returned. 
The component must also implement a handler for the event and register it during creation of POE::Session. 
 
=cut 

=item getWakeUpHandler() OPTIONAL

Must return the name of the event which wakes the component up. The wake up event is yield when the container initialisation is 
finsished.

=cut


=head1 METHODS

=cut

=item new ($options)

Constructor for Copilot::Component object. Takes as an input hash reference with options. The constructor 
creates the object of the needed class (e.g. Copilot::Component::JobAgent) and calls its _init() function with 
$options as an argument. For options which are passed to Copilot::Component please see the documentation of 
Copilot::Container.

Users of this class must not create objects of Copilot::Component, instead they must instantiate one of the child classes 
of Copilot::Container and give the name of component to be created as the value of 'Component' parameter. 

Example:

my $jm = new Copilot::Container::XMPP (
                                          {
                                              Component => 'JobManager', # The object of Copilot::Component::JobManager will be created
                                          }
                                      );

=cut


use vars qw (@ISA);

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

"M";
