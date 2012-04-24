package Copilot::Config::AliEn;

=pod 

=head1 NAME Copilot::Config::AliEn

This class provides AliEn specific configuration information. It is child class  
of Copilot::Config, so Copilot::Config::AliEn objects contain all the data which Copilot::Config objects
have + AliEn specific configuration parameters.

=cut

use Copilot::Config;
use AliEn::Config;

use strict;
use warnings;

use vars qw (@ISA);

@ISA = ("Copilot::Config");

=head1 METHODS

=cut


=item new()

Constructor for Copilot::Config::AliEn object. Creates the object of Copilot::Config and appends 
to it AliEn specific configuration options (Uses AliEn::Config)

=cut


sub new
{
    my $proto = shift;
    my $class = ref ($proto) || $proto;
    my $options = shift;
    
    my $self = $class->SUPER::new($options);

    my $config = AliEn::Config->new();

    $self->{'WN_SI2K_PRICE'} = 10;
    $self->{'SEs_FULLNAME'} = $config->{'SEs_FULLNAME'}; #['sad'];

    $self->{'CE_FULLNAME'} = $config->{'CE_FULLNAME'}; #'asda';
    $self->{'CE_HOST'} = $config->{'CE_HOST'}; #'asdadasd';

    $self->{'GRID_PARTITION'} = $config->{'GRID_PARTITION'}; # 'asdad';
    $self->{'GRID_PARTITION_LIST'} = $config->{'GRID_PARTITION_LIST'}; #['asdad'];

    $self->{'CE_TTL'} = '216000';

    return $self;    
}

"M";
