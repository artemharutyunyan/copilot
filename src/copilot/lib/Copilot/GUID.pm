package Copilot::GUID;

=pod

=head1 NAME Copilot::GUID

PERL wrapper for uuidgen command line tool

Example:

use Copilot::GUID;
my $guid = new Copilot::GUID;
my $newguid = $guid->CreateGuid();
print "GUID: $newguid\n"; 

=cut

=head1 METHODS

=item new()

Constructor for Copilot::GUID

=item CreateGuid()

Creates and returns GUID

=cut 


use strict;

sub new {
  my $proto = shift;
  my $GUID   = (shift or "");
  my $self  = {};
  bless( $self, ( ref($proto) || $proto ) );
  
  return $self;
}

sub CreateGuid 
{
    my $self = shift;
    
    my $guid = `uuidgen`;
    chomp $guid;
    
    return $guid; 
}


"M";
