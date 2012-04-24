#
# Class for appending  AliEn specific attributes to the host JDL 
#
package Copilot::Classad::Host::AliEn;

=head1 Copilot::Classad::Host::AliEn
 
=head1 DESCRIPTION

This is a class for constructing a AliEn specific JDL on the nodes where copilot agent runs. Inherits from Copilot::Classad::Host

=head1 METHODS 

=item new( $jdl ) 

If Classad object is provided (through $jdl input variable) then constructor appends AliEn specific information to it and returns. 
Otherwise constructs new Classad objects using Copilot::Classad::Host, appends AliEn specific variables to the new object and returns. 

AliEn specific variables are CloseSE, CE, GridPartitions, TTL, Price, Packages and InstalledPackages.

=cut


use Copilot::Classad::Host;
use Copilot::Config::AliEn;

use vars qw (@ISA);

use strict;
use warnings;

@ISA =  ("Copilot::Classad::Host");

sub new
{
    my $proto = shift;
    my $class = ref ($proto) || $proto;
    my $self = {};    
    bless ($self, $class);

    my $jdl = shift || "";    

    $self->{CONFIG} or $self->{CONFIG} = Copilot::Config->new();
    $self->{CONFIG} or return;

    if ($jdl) 
    {
        $self->{'ca'} = $self->getHashFromJDLString($jdl);        
    }
    else
    {
        $self->{'ca'} = $self->SUPER::new()->{'ca'};
            
    }
    
    return $self->appendAliEnAttributes ();   
}

sub appendAliEnAttributes 
{
    my $self = shift;

    $self->{CONFIG} = new Copilot::Config::AliEn();

    $self->setCloseSE() or return;
    $self->setCE () or return;
    $self->setGridPartitions() or return;
    $self->setTTL() or return;
    $self->setPrice() or return;
    $self->setPackages() or return;

    return $self;  
}

#
# Puts closest SE name into JDL
sub setCloseSE
{
  my $self=shift;
  my $ca=shift;
  my @closeSE = ();

  $self->{CONFIG}->{SEs_FULLNAME}
    and @closeSE = @{ $self->{CONFIG}->{SEs_FULLNAME} };

  return $self->setAttribute("CloseSE", @closeSE);
}

#
# Puts CE name and host to the JDL
sub setCE 
{
    my $self=shift;
    my $ca=shift;

    if ($self->{CONFIG}->{CE_FULLNAME}) 
    {
        $self->setAttribute( "CE", $self->{CONFIG}->{CE_FULLNAME} )
        or $self->_log( "Error setting the CE ($self->{CONFIG}->{CE_FULLNAME})", 'error' )
        and return;
    }

    if ($self->{CONFIG}->{CE_HOST})
    {
        $self->setAttribute( "Host", $self->{CONFIG}->{CE_HOST} )
        or $self->_log( "Error setting the CE ($self->{CONFIG}->{CE_HOST})", 'error' )
        and return;
    }

    return 1;
}

#
# Puts grid partitions to the JDL
sub setGridPartitions
{
    my $self=shift;
    my $ca=shift;

    ( $self->{CONFIG}->{GRID_PARTITION} ) or return 1;
    my  @partitions=@{ $self->{CONFIG}->{GRID_PARTITION_LIST} };
    return $self->setAttribute( "GridPartitions", @partitions);

}

#
# Puts TTL to the JDL
sub setTTL 
{
    my $self=shift;
    my $ca=shift;

    my $ttl=($self->{CONFIG}->{CE_TTL} or  "");

    ($ttl) or $self->_log( "Using default TTL value: 12 hours", 'info')  and $ttl=12*3600;

    return $self->setAttributeNoQuote('TTL', $ttl);
}

#
# Puts the price into JDL
sub setPrice
{
    my $self = shift;
    my $ca = shift;

    my $price = ($self->{'CONFIG'}->{'WN_SI2K_PRICE'} || 1);

    my $p = sprintf ("%.2f", $price);
    return $self->setAttributeNoQuote ("Price", $p);
}

#
# Puts to JDL the list of available packages (Packages and InstalledPackages items)
sub setPackages
{
    my $self = shift;
    my $ca = shift;

    my @packages = $self->_getAvailablePackages();
    my @installedPackages = $self->_getInstalledPackages();

    $self->setAttribute ("Packages", @packages) or return;
    $self->setAttribute ("InstalledPackages", @installedPackages) or return;

    return 1;
}


#
# Returns the list of available packages 
sub _getAvailablePackages
{
   my $self = shift;  

   # for the time being we let this like it is   
   # in future it will be changed probably
   my $packages = `alienv --packman list`;
   return split ("\n", $packages);
}

#
# Returns the list of installed packages
sub _getInstalledPackages
{
    my $self = shift;  

    # for the time being we let this like it is 
    # in future it will be changed probably
    my $packages = `alienv --packman list`;
    return split ("\n", $packages);
}


"M";
