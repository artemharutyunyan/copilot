package Copilot::Component::Heartbeat;

=head1 NAME Copilot::Component::Heartbeat;

=head1 DESCRIPTION

This class implements the remote introspection utility, aka Heartbeat. The component is a subclass of Copilot::Component meaning that it has to be instantiated within on of the component containers (e.g. Copilot::Container::XMPP). The following data has to be provided via 'ComponentOptions' parameter:

  Component - Name of the component whose status will be requested (eg. diskUsage, systemLoad, etc.)
  Jid       - JID of the Copilot Component to which the request will be sent.

Example usage:
my $hb = new Copilot::Container::XMPP({
                    Component     => 'Heartbeat',
                    LoggerConfig   => $loggerConfig,
                    JabberID     => $jabberID,
                    JabberPassword   => $jabberPW,
                    JabberDomain   => $jabberDomain,
                    JabberServer   => $jabberServer,
                    ChatServer     => $jabberChatServer,
                    ChatRoom      => $jabberChatRoom,
                    ComponentOptions => {
                                Component => 'systemLoad',
                                Addresses => [$destinationJid],
                                ChatRoomAddress => $jabberChatRoom . '@' . $jabberChat
                              },
                   });

=cut

use strict;
use warnings;

use vars qw (@ISA);
our $VERSION='0.1';

use Copilot::Component;
use Copilot::Util;

use POE;
use POE::Component::Logger;

use Data::Dumper;

@ISA = ('Copilot::Component');

sub _init
{
  my $self    = shift;
  my $options = shift;

  # Read configuration
  $self->_loadConfig($options);

  # Create POE session
  my $inputHandler = $self->{'COMPONENT_INPUT_HANDLER'};
  POE::Session->create (
                          inline_states => {
                                              _start => \&mainStartHandler,
                                              _stop  => \&mainStopHandler,

                                              $inputHandler               => \&componentInputHandler,
                                              componentProcessResponse    => \&componentProcessResponse,
                                              componentProcessPong        => \&componentProcessPong,
                                              componentSendStatusRequest  => \&componentSendStatusRequest,
                                              componentBroadcastPing      => \&componentBroadcastPing,

                                              componentExit               => \&componentExit,
                                           },
                          args => [ $self ]
                      );

  return $self;
}

sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    # Name will be used as an alias for POE session created by the component
    $self->{'COMPONENT_NAME'} = $options->{'COMPONENT_NAME'};

    # Name of the container's POE session alias
    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
      or die "CONTAINER_ALIAS is not specified. Can't communicate with the server.\n";

    # Event which takes care of logging
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'}) || 'logger';

    # Name of the container's event used for sending messages to the outer world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
      or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the outer world.\n";

    # This components' event used for processing input events
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentInputHandler';

    # JID of the chat room (chat room)@(chat server)
    $self->{'CHAT_ROOM_ADDRESS'} = $options->{'COMPONENT_OPTIONS'}->{'ChatRoomAddress'};

    # Command and addresses (JIDs), the command line arguments
    $self->{'COMMAND'} = $options->{'COMPONENT_OPTIONS'}->{'Command'} || '';
    $self->{'COMPONENT_ADDRESSES'} = $options->{'COMPONENT_OPTIONS'}->{'Addresses'} || '';
}

sub mainStartHandler
{
    my ($kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;

    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    my $command = $self->{'COMMAND'};
    my $handler = $command eq 'list' ? 'componentBroadcastPing' : 'componentSendStatusRequest';
    $kernel->delay ($handler, 1);
}

sub mainStopHandler
{
  
}

sub getInputHandler
{
    my $self = shift;
    return $self->{'COMPONENT_INPUT_HANDLER'};
}

sub componentInputHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    my $command = $input->{'command'};

    if ( $command eq 'haveStatus' )
    {
      $kernel->yield('componentProcessResponse', $input);
    }
    elsif ( $command eq 'pong' )
    {
      $kernel->yield('componentProcessPong', $input);
    }
    else
    {
      my $container = $self->{'CONTAINER_ALIAS'};
      my $logHandler = $self->{'LOG_HANDLER'};

      $kernel->post ($container, $logHandler, "Received an unknown command: $command. Ignoring.");
    }
}

sub componentBroadcastPing
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};

    my $container   = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
    my $logHandler  = $self->{'LOG_HANDLER'};

    my $to = $self->{'CHAT_ROOM_ADDRESS'};
    my $ping = {
                  'to'        => $to,
                  'noack'     => '1',
                  'broadcast' => '1',
                  'info' => {
                              'command' => 'Heartbeat:ping',
                            },
               };
    
    $kernel->post ($container, $logHandler, "Sending ping command to the chat room ($to).", 'debug');
    $kernel->post ($container, $sendHandler, $ping);
}

sub componentSendStatusRequest
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};

    my $container   = $self->{'CONTAINER_ALIAS'};
    my $logHandler  = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $chatAddress = $self->{'CHAT_ROOM_ADDRESS'};
    my $command     = $self->{'COMMAND'};
    my @jids        = split (' ', $self->{'COMPONENT_ADDRESSES'});
    my $jidsCount   = @jids;

    # if the address isn't provided we're sending the message to the chatroom
    $jids[0] = $chatAddress unless length ($jids[0] || '');

    # since we don't know the number of occupants we won't know when to properly exit
    $heap->{'EXPECTED_RESPONSES'} = ($jids[0] eq $chatAddress) ? -1 : $jidsCount;
    $heap->{'RECEIVED_FIRST_RESPONSE'} = '0';

    $kernel->post ($container, $logHandler, "Requesting $command status.");
    
    foreach my $jid (@jids)
    {
      # if the user provided just a roomnick
      $jid = $chatAddress . '/' . $jid if index ($jid, '@') == -1;

      my $request = {
                      'to'          => $jid,
                      'info'        => {
                                        'command'     => 'Heartbeat:getStatus',
                                        'component'   => $command,
                                       },
                    };
      $request->{'broadcast'} = '1' if $jid eq $chatAddress;
      
      $kernel->post($container, $sendHandler, $request);
    }
}

sub componentProcessResponse
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    #print ">>>" .  $input->{'status'} . "\n";
    my $response = Copilot::Util::stringToHash ($input->{'status'});
    my @keys = keys %$response;

    if ( $heap->{'RECEIVED_FIRST_RESPONSE'} == '0' )
    {
        $heap->{'RECEIVED_FIRST_RESPONSE'} = '1';
        my $header = join ("\t\t", @keys);
        print "Room nick\t\t\t\t" . $header . "\n";
    }

    my ($chatroom, $from) = split ('/', $input->{'from'});
    my $firstValue = $response->{$keys[1]};

    if (ref $firstValue eq 'ARRAY')
    {
        # if there was more than one row sent
        my $firstRow  = $response->{$keys[0]};
        my $rowLength = scalar @$firstRow;

        while ($rowLength--)
        {
            print $from . "\t";
            for my $key (@keys)
            {
                my $values = $response->{$key};
                my $value = shift @$values;
                print $value . "\t\t";
            }
            print "\n";
        }
    }
    else
    {
        print $from . "\t" . (join ("\t\t", values %$response)) . "\n";
    }

    if ( --$heap->{'EXPECTED_RESPONSES'} == 0 )
    {
        $kernel->post ($container, $logHandler, 'All expected responses have been received. Exiting.', 'debug');
        exit 0;
    }
    elsif ( $heap->{'EXPECTED_RESPONSES'} < 0 )
    {
        # Since we don't know the number of responses we will receive
        $kernel->post ($container, $logHandler, 'No responses were received in the past 10s. Exiting.', 'debug');
        # delay() will reset an alarm with the same name if it already exists
        $kernel->delay (componentExit => 10);
    }
}

sub componentProcessPong
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my ($chatRoom, $from) = split ('/', $input->{'from'});

    $kernel->post ($container, $logHandler, "Received a pong response from $from.", 'debug');
    print $from . "\n";

    $kernel->delay (componentExit => 10);
}

sub componentExit
{
    exit 0;
}

"M";
