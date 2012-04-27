#
# Class for generation of the JDL of the host
#
package Copilot::Classad::Host;

=head1 Copilot::Classad::Host
 
=head1 DESCRIPTION

This is a class for constructing a JDL on the nodes where copilot agent runs.  

=head1 METHODS 

=item new() 

Constructs JDL string and returns it. The string contains information about the version of the agent software, 
disk space, memory, system and arcitecture (retrieved using 'uname' command).


=cut

use Filesys::DiskFree;

use Copilot::Config;

use strict;
use warnings;

sub new 
{
    my $proto = shift;
    my $class = ref ($proto) || $proto;
    my $self = (shift or {});
    bless ($self, $class);
   
    
    $self->{CONFIG} or $self->{CONFIG} = Copilot::Config->new();
    $self->{CONFIG} or return;

#   my $ca = Classad::Classad->new ( "[ Type=\"machine\"; Requirements=(other.Type==\"Job\"); WNHost = \"$self->{CONFIG}->{HOST}\"; ]" );

#    $self->{'ca'} = '[ Type="machine"; Requirements=(other.Type=="Job"); WNHost = '.$self->{CONFIG}->{HOST}.'"; ]';
 
    $self->{'ca'} = {};
    
    $self->{'ca'}->{'Type'} = "\"machine\"";
    $self->{'ca'}->{'Requirements'} = "(other.Type==\"Job\")";
    $self->{'ca'}->{'WNHost'} ='"'.$self->{'CONFIG'}->{'HOST'}.'"';
    
    $self->setVersion() or return;
    $self->setDiskSpace() or return;
    $self->setUname() or return;
    $self->setMemory()or return;
    $self->setPlatform() or return;

    return $self;
}

#
# Puts the version into the JDL 
sub setVersion
{
    my $self = shift;

    my $version = ($self->{'CONFIG'}->{'VERSION'} || "0");

    return $self->setAttribute("Version", $version);
}

#
# Puts local disk space information into the JDL 
sub setDiskSpace
{
    my $self = shift;

    my $dir = $ENV{HOME};

    # Set the free disk space 
    my $handle = Filesys::DiskFree->new();
    $handle->df();
    my $freeSpace = $handle->avail($dir);

    if ($freeSpace)
    {
        return $self->setAttributeNoQuote( "LocalDiskSpace", $freeSpace/1024);
    }
    else
    {   
        $self->_log('Error getting free diskspace', 'error');
        return;
    }

}

#
# Puts uname into the JDL
sub setUname
{
    my $self = shift;  
    
    # Set uname 
    if (open (UNAME, "uname -r |")) 
    {
        my $uname=join("", <UNAME>);
        close UNAME;
        chomp $uname;
        return $self->setAttribute("Uname", $uname );
    }
    else 
    {
        $self->info("Error getting uname");
        return;
    }
}

#
# Puts memory and swap space information into the JDL
sub setMemory
{
    my $self = shift;

    open (MEMINFO,"</proc/meminfo") or $self->_log("Error checking /proc/meminfo", 'error') 
        and return 1;

    my ($freeMem, $freeSwap, $totalMem, $totalSwap);

    foreach (<MEMINFO>) 
    {
        if (/^SwapTotal:\s*(\d+)\s+/) 
        {
            $totalSwap = int($1/1024);
            next;
        }

        if (/^SwapFree:\s*(\d+)\s+/)
        {
            $freeSwap = int($1/1024);
            next; 
        }

        if (/^MemTotal:\s*(\d+)\s+/) 
        {
            $totalMem = int($1/1024);
            next;
        }

        if (/^MemFree:\s*(\d+)\s+/)
        {
            $freeMem = int($1/1024);
            next; 
        }
    }
    
    close MEMINFO;

    $totalSwap and ( $self->setAttributeNoQuote("Swap", $totalSwap) or return);
    $totalMem and ( $self->setAttributeNoQuote("Memory", $totalMem) or return);
    $freeMem and ( $self->setAttributeNoQuote("FreeMemory", $freeMem) or return);
    $freeSwap and ($self->setAttributeNoQuote("FreeSwap", $freeSwap) or return);

    return 1;
}

#
# Puts platform information into the JDL
sub setPlatform
{
    my $self = shift;

    # check if platform is defined in Config
    my $platform = $self->{CONFIG}->{PLATFORM_NAME};

    if ( !$platform )
    {
        my $kernelName = `uname -s`;
        chomp $kernelName;
        $kernelName =~ s/\s//g; # strip spaces out

        my $arch = `uname -m`;
        chomp $arch;
        $arch =~ s/\s//g; # strip spaces out
    
        $platform = "$kernelName-$arch"; 
    }

    return $self->setAttribute("Platform", $platform); 
} 

#
# This method gets as an input the JDL, the attribute name and the list of values.
# It inserts the attribute (with the corresponding values) to the JDL 
sub setAttribute
{
    my $self = shift;
    my $attribute = shift;
    my @values = @_;

    ($#values > -1) or return 1; # check that at least one value was supplied

    map { s/^(.*)$/\"$1\"/ } @values; # put values into quotes

    my $string = "";
    ($#values > 0) or ( $string = $values[0]); # if the list contains only one value, we don't need brackets
    $string or ($string = "{". join (", ", @values) ."}"); # put all values into the string and append brackets

    #$ca->set_expression ($attribute, $string) or $self->_log("Error setting the $attribute (@values)") and return;  
    $self->appendAttribute ( $attribute, $string);   
    
    return 1;  
}

sub setAttributeNoQuote
{
    my $self = shift;
    my $attribute = shift;
    my @values = @_;

    ($#values > -1) or return 1; # check that at least one value was supplied

    my $string = "";
    ($#values > 0) or ( $string = $values[0]); # if the list contains only one value, we don't need brackets
    $string or ($string = "{". join (", ", @values) ."}"); # put all values into the string and append brackets

    # $ca->set_expression ($attribute, $string) or $self->_log("Error setting the $attribute (@values)") and return;
    $self->appendAttribute ($attribute, $string);
    
    return 1;  
}

#
# Append a new attribute=value pair to the JDL
sub appendAttribute
{
    my $self = shift;

    my $attribute = shift;
    my $string = shift;   
    
    $self->{'ca'}->{$attribute} = $string;

    return 1;
}

#
# Method for logging 
sub _log
{
    my $self = shift;
    my $msg = shift;
    my $level = shift; # currently we igonre it 

    print $msg,"\n";
    return 1;
}

sub asJDL
{
    my $self = shift;
    
    my $ca = $self->{'ca'};
    
    my $retStr = "[\n";
    
    foreach my $key (keys %$ca)
    {
        $retStr .= "$key=".$ca->{$key}.";\n";
    }
    
    $retStr .= "]\n";
    
    return $retStr;
}

sub getHashFromJDLString
{
    my $self = shift;
    my $jdl = (shift || $self->{'ca'});

    $jdl =~ s/\]|\[//g;

    my $ret = {};

    foreach my $element (split(';', $jdl))
    {   
        next unless $element =~ /=/;
        
        my ($attr, @value) = split ('=', $element);
        
        $ret->{$attr}= join ('=', @value);
    }   

    return $ret;
}

"M";
