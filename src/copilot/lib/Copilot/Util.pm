package Copilot::Util;

use strict;

use Data::Dumper;
use XML::Simple;

use POE::Filter::XML::Node;
use MIME::Base64;

=pod

=head1 NAME Copilot::Util

A package which contains different utility functions


=cut

=head1 FUNCTIONS


=item hashToXMLNode()

Converts perl hash to POE::Filter::XML::Node object

=cut

sub hashToXMLNode
{
    my $h = shift;
    my $name = shift || "body";

    my $node = POE::Filter::XML::Node->new($name);

    foreach my $key (keys %$h)
    {
        my $value = $h->{$key};
        if (ref($value) eq 'HASH')
        {
            my $child = hashToXMLNode ( $value, $key);
            $node->insert_tag ($child);
            next;
        }

        # append '_BASE64' before encoded string
        $node->attr ($key, "_BASE64:".encode_base64($value));
    }

    return $node;
}

=item XMLNodeToHash()

Converts POE::Filter::XML::Node object to perl hash

=cut

sub XMLNodeToHash
{
    my $node = shift;
    my $hr = {};

    $hr = $node->get_attrs();

    foreach my $key (keys %$hr)
    {
        # check if the value needs to be Base64 decoded (in hashToXMLNode we append '_BASE64' before encoding string)
        $hr->{$key} =~ s/(^_BASE64)//;
        $1 or next;

        $hr->{$key} = decode_base64 ($hr->{$key});
    }

    my $children = $node->get_children();

    foreach my $child (@$children)
    {
        my $name = $child->name();
        $hr->{$name} = XMLNodeToHash ($child);
    }

    return $hr;
}

=item XMLStringToHash

Converts an XML string to hash

=cut

sub XMLStringToHash
{
    my $string = shift;
    my $xm = new XML::Simple;
    $XML::Simple::PREFERRED_PARSER="XML::Parser";
    return $xm->XMLin ($string);
}

=item decodeBase64Hash

Base64 decodes the values of the hash

=cut

sub decodeBase64Hash
{
    my $hashRefBase64 = shift;
    my $hashRefDecoded = {};

    foreach my $key (keys %$hashRefBase64)
    {
        my $value = $hashRefBase64->{$key};
        if (ref ($value) eq 'HASH')
        {
            $hashRefDecoded->{$key} = decodeBase64Hash ($value);
            next;
        }

        $value =~ s/(^_BASE64)//;
        $1 and ($value = decode_base64($value));
        $hashRefDecoded->{$key} = $value;
    }

    return $hashRefDecoded;
}

=item hashToString

Serializes a 1D hash into a string

=cut

sub hashToString
{
    my $hash = shift;
    my $string = '';

    foreach my $key (keys %$hash)
    {
        my $value = $hash->{$key};
        if (ref $value eq 'ARRAY')
        {
            $value = join ('::::', @$value);
        }
        $string .= $key . '=' . $value . '####';
    }

    return $string;
}

=item stringToHash

Deserializes a string created with hashToString() back into a hash

=cut

sub stringToHash
{
    my $string = shift;
    my $hash = {};

    my @pairs = split ('####', $string);
    foreach my $pair (@pairs)
    {
        my ($key, $value) = split ('=', $pair, 2);
        if (index ($value, '::::') != -1)
        {
            my @values = split ('::::', $value || '');
            $hash->{$key} = \@values;
        }
        else
        {
            $hash->{$key} = $value;
        }
    }

    return $hash;
}

=item groupHashesByKeys

Takes an array of hashes and groups values by keys.

Example
    groupHashByKey([{'a' => 1, 'b' => 2,}, {'a' => 2, 'b' => '3'}])
    => {'a' => [1, 2], 'b' => [2, 3]}

=cut

sub groupHashesByKeys
{
    my @hashes = @_;
    my $count = @hashes;
    my $grouped = {};

    foreach my $hash (@hashes)
    {
        next if ref $hash eq 'ARRAY';

        foreach my $key (keys %$hash)
        {
            my $groupedKey = $grouped->{$key};
            $groupedKey = $grouped->{$key} = [] if (ref $groupedKey ne 'ARRAY');

            push (@$groupedKey, $hash->{$key});
        }
    }

    return $grouped;
}

=item ungrupHashByKey

Expands hashes created with 'groupHashesByKeys' into their original state

=cut

sub ungroupHashByKey
{
    my $grouped = shift;
    my @hashes = [];

    my @keys = keys %$grouped;
    my $firstRow = $grouped->{$keys[0]};
    my $count = scalar @$firstRow;

    while ($count--)
    {
        my $hash = {};
        foreach my $key (@keys)
        {
            my $values    = $grouped->{$key};
            my $value     = shift @$values;
            $hash->{$key} = $value;
        }

        push (@hashes, $hash);
    }

    return @hashes;
}

=item trim

Removes both leading and trailing whitespace of a string.

=cut

sub trim
{
    my $string = shift;
    $string =~ s/^\s+|\s+$//g;
    return $string;
}

=item getCPULoad

Returns CPU load over past minute, five minutes and 15 minutes.

=cut

sub getCPULoad
{
    my $cmd = `uptime`;
    my @uptimeChunks = split (': ', $cmd);
    my @loadAvgs = split(', ', $uptimeChunks[-1]);
    $loadAvgs[2] = trim ($loadAvgs[2]);

    return @loadAvgs;
}


=item getDiskUsage

Returns disk usage.

=cut

sub getDiskUsage
{
    my $cmd = `df --block-size=M`;
    my @lines = split (/\n/, $cmd);
    shift (@lines); # Header

    $cmd = join (' ', @lines);
    my @chunkedData = split (/\s+/, $cmd);

    my $diskUsage = {};
    my $i = -1;
    my $n = @chunkedData;
    while ($i < $n - 1)
    {
        my $devicePath = $chunkedData[++$i] || '';
        my $blockSum   = $chunkedData[++$i];
        my $used       = $chunkedData[++$i] || '0M';
        my $available  = $chunkedData[++$i] || '0M';
        my $usedPerc   = $chunkedData[++$i];
        my $mountpoint = $chunkedData[++$i];

        my @pathParts = split ('/', $devicePath);
        @pathParts and (my $deviceName = trim ($pathParts[-1]));

        chop $used;      # Removes 'M' from strings
        chop $available;

        $diskUsage->{$deviceName} = {
                                        'path'          => $devicePath,
                                        'totalBlocks'   => $blockSum,
                                        'used'          => $used,
                                        'available'     => $available,
                                        'used%'         => $usedPerc,
                                        'mountpoint'    => $mountpoint,
                                     };
    }

    return $diskUsage;
}

=item getRAMUsage

Returns usage statistics for RAM and swap

=cut

sub getRAMUsage
{
    my $cmd = `free -om`;
    my @lines = split(/\n/, $cmd);
    shift (@lines); # Removes header

    my $ramUsage = {};
    foreach my $line (@lines)
    {
        my ($memName, $total, $used, $available) = split (/\s+/, $line);
        $memName = lc trim ($memName);
        chop $memName;

        $ramUsage->{$memName} = {
                                    'used'      => trim ($used),
                                    'available' => trim ($available),
                                };
    }

    return $ramUsage;
}


=item getNetworkUsage

Parses network information and returns an object

=cut

sub getNetworkUsage
{
    open (NETSTAT, '</proc/net/dev');
    my $lineNo = 0;
    my $networkIO = {};
    while (my $line = <NETSTAT>)
    {
        $lineNo++;

        if ($lineNo <= 2)
        {
            next;
        }

        my ($interface, $inout) = split (/:/, $line);
        my @numbers = split (/\s+/, trim ($inout));
        $interface = trim ($interface);

        # We've reached end of file
        if ( $interface eq '' and length @numbers == 0)
        {
            next;
        }

        # bandwidth is converted from bytes to megabytes
        $networkIO->{$interface} =  {
                                        'in'  => $numbers[0]/1024/1024,
                                        'out' => $numbers[9]/1024/1024,
                                    };
    }
    close (NETSTAT);

    return $networkIO;
}

sub getRunningProcesses
{
    my $cmd = `ps ux`;

    my @processes = split ("\n", $cmd);
    my @header = split (/\s+/, shift @processes, 11);
    my $n = @header;
    my @result = [];

    foreach my $line (@processes)
    {
        my @lineData = split (/\s+/, $line, 11);
        my $proc = {};

        for (my $ i = 0; $i < $n; $i++)
        {
            $proc->{lc $header[$i]} = $lineData[$i];
        }

        push (@result, $proc);
    }

    return @result;
}

"M";
