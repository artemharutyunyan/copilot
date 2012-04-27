package Copilot::Config;

=pod 

=head1 NAME Copilot::Config 

This class provides configuration information for the components of Copilot system. 
Later it can be changed, so it gets the configuration from LDAP server or other 
source. 

=cut

use strict;
use warnings;

use Data::Dumper;

=head1 METHODS

=cut


=item new()

Constructor for Copilot::Config object.

=cut

sub new
{
    my $proto = shift;
    my $class = ref ($proto) || $proto;
    my $self = {};
    bless ($self, $class);

    my $componentName = shift || '';
    
    $self->{'HOST'} = `hostname -f`;
    chomp $self->{'HOST'};

    $self->{'VERSION'} = "0";

    $self->{'PLATFORM_NAME'} = '';
   
    # Read general configuration file
    my $optional = 1;	
    my $configDir = ($ENV{'COPILOT_CONFIG'} || '/etc/copilot/');    

    $self->readConfigFile ($configDir."/Copilot.conf", $optional );
    $componentName and $self->readConfigFile($configDir."/$componentName.conf");
   
    return $self;
}

#
# Reads the configuration from given config file. Appends data read to $self 
sub readConfigFile
{
    my $self = shift;
    my $configFile = shift;
    my $optional = shift || 0;	

    my $line;
    unless (open FH, "< $configFile")
    { 
        $optional or die "Can not open config file ($configFile): $!\n";
        return;
    }
    while ($line = <FH>)
    {
        next if $line =~ /^\s*#/;
        my ($param, $value) = split (/\s+/, $line);
        next unless $param;

        #print "P: $param V: $value\n";
        $self->{$param} = ($ENV{$param} || $value);
    }
    close FH;
   
}
"M";
