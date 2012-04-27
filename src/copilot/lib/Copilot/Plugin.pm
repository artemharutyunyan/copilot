package Copilot::Plugin;

=head1 NAME Copilot::Plugin

=head1 DESCRIPTION

This is a base class for Co-Pilot plugins (e.g. SystemMonitor), and it must be instantiated inside a container (e.g. Copilot::Container::XMPP).

Plugins inheriting this class must provide following methods:

=item _init($options)

This function is called from the constructor. Component initialization and POE::Session creation
must be done within this function.

=cut


=head1 METHODS

=cut

=item new ($options)

Used for constructing the Copilot::Plugin object. The constructor
creates the object of the needed class (e.g. Copilot::Plugin::SytemMonitor) and calls its _init() function with
$options as an argument. For details see the documentation of Copilot::Container.

This class shall not be created directly, instead use one of the Copilot::Container child classes and give the name of the plugin
in a hash reference 'Plugins'.

Example:

my $jm = new Copilot::Container::XMPP (
                                          {
                                              Plugins => {
                                                          SystemMonitor => {}, # SystemMonitor plugin will be instantiated
                                                          DiskCleaner => {
                                                                            Interval => 60,
                                                                         },
                                                         }
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