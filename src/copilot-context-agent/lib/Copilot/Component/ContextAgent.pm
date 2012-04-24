package Copilot::Component::ContextAgent;

=head1 NAME Copilot::Component::ContextAgent

=head1 DESCRIPTION

This class implements the Context Agent of the Copilot system, it inherits from Copilot::Component (for general information 
about the Components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within 
one of the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during 
instantiation via 'ComponentOptions' parameter:

    CMAddress - Jabber ID of the Context Manager
    WorkDir   - Temporary directory where the agent will keep files  
    ContextID - ID of the context which needs to be retrieved and applied 

    Exmaple:

my $agent = new Copilot::Container::XMPP (
                                    {
                                      Component => 'ContextAgent',
                                      LoggerConfig => $loggerConfig,
                                      JabberID => $jabberID,
                                      JabberPassword => $jabberPassword,
                                      JabberDomain => $jabberDomain,
                                      JabberServer => $jabberServer,
                                      ComponentOptions => {
                                                            CMAddress  => $JMAddress,
                                                            WorkDir    => '/tmp/agentWorkdir',
                                                            ContextID  => $contextID,
                                                            ContextKey => $contextKey,
                                               		  },
                                     SecurityModule => 'Consumer',
                                     SecurityOptions => {
                                                         KMAddress => $keyServerJID,
                                                         TicketGettingCredential => 'blah', 
                                                         PublicKeysFile => '/etc/copilot/PublicKeys.txt',
                                                        },

                                    }
                                  );


=cut


use POE;
use POE::Wheel::Run;

use vars qw (@ISA);
our $VERSION="0.01";

use Copilot::Component;
use Copilot::GUID;

use strict;
use warnings;


use Data::Dumper;
use MIME::Base64;

@ISA = ("Copilot::Component");

sub _init
{
    my $self    = shift;
    my $options = shift;


    #
    # Read config 
    $self->_loadConfig($options);

    #
    # Create POE session
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'COMPONENT_INPUT_HANDLER'} =>  \&componentInputHandler,
                                                $self->{'COMPONENT_WAKEUP_HANDLER'} => \&componentWakeUpHandler,
                                                componentProcessInput => \&componentProcessInputHandler,
                                                componentGetContext => \&componentGetContextHandler,
                                                componentApplyContext => \&componentApplyContextHandler,
                                                componentStartAmiconfig => \&componentStartAmiconfigHandler,
                                                    contextWheelFinished => \&contextWheelFinishedHandler,
                                                    contextWheelStdout => \&contextWheelStdoutHandler,
                                                    contextWheelStderr => \&contextWheelStderrHandler,
                                                    contextWheelError => \&contextWheelErrorHandler,
                                                componentLogMsg => \&componentLogMsgHandler,
                                                componentRedirect => \&componentRedirectHandler,
                                            },
                                     args => [ $self ],
                         ); 

    return $self;
}

#
# Loads config parameters into $self
sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    # Will be used an alias for this component
    $self->{'COMPONENT_NAME'} = $options->{'COMPONENT_NAME'};
    
    # Server's session alias
    ($self->{'CONTAINER_ALIAS'} = $options->{'CONTAINER_ALIAS'})
        or die "CONTAINER_ALIAS is not specified. Can't communicate with the container\n"; 

    # Event in server, which handles the messages sent from component to the outer world
     ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't send messages out.\n"; 

    # Event, which handles server input inside the component
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentHeandleInput';    

    # Event, which handles wake up inside the component (called once, when client is connected to the component)
    $self->{'COMPONENT_WAKEUP_HANDLER'} = 'componentHandleWakeUp';

    # CM Host    
    $self->{'CONTEXT_MANAGER_ADDRESS'} = $options->{'COMPONENT_OPTIONS'}->{'CMAddress'};
    $self->{'CONTEXT_MANAGER_ADDRESS'} or die "Context manager address is not provided.\n";

    # Agent workdir
    $self->{'CONTEXT_AGENT_WORKDIR'} = $options->{'COMPONENT_OPTIONS'}->{'WorkDir'};
    $self->{'CONTEXT_AGENT_WORKDIR'} || ( $self->{'AGENT_WORKDIR'} = '/tmp/contextAgentWorkdir');

    # Context ID
    $self->{'CONTEXT_ID'} = $options->{'COMPONENT_OPTIONS'}->{'ContextID'};
    $self->{'CONTEXT_ID'} or die "Context ID is not provided\n.";    

    $self->{'CONTEXT_KEY'} = $options->{'COMPONENT_OPTIONS'}->{'ContextKey'};
    $self->{'CONTEXT_KEY'} or die "Context key (an authentication token) is not provided\n.";    

    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger'); 
    
    $self->{'DEBUG'} = ($options->{'COMPONENT_OPTIONS'}->{'Debug'} || '0');
}

#
# Called before the session is destroyed
sub mainStopHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    
    $kernel->post($container, '_stop'); #exit 
}

#
# Called before session starts 
sub mainStartHandler
{
    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;
   
    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    $self->{'DEBUG'} && $_[SESSION]->option (trace => 1);
}

#
# Returns the name of input handler 
sub getInputHandler
{ 
    my $self = shift;
    return $self->{'COMPONENT_INPUT_HANDLER'}; 
}

#
# Returns the name of wake up handler 
sub getWakeUpHandler
{ 
    my $self = shift;
    return $self->{'COMPONENT_WAKEUP_HANDLER'}; 
}


#
# Handles wake up 
sub componentWakeUpHandler
{

   my ($kernel, $sender, $heap) = @_[ KERNEL, SENDER, HEAP ];

   my $self = $heap->{'self'}; 

   #
   # Save the session ID of the server
   $heap->{'sender'} = $sender;

   #
   # Ask for a context
   $kernel->yield ('componentGetContext'); 


   # Write to log file
   $kernel->yield ('componentLogMsg', "Component was waken up. Asking context manager for a context", 'info');
}

#
# Handles input from server 
sub componentInputHandler
{

    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $logHandler = $self->{'LOG_HANDLER'};
    my $container = $self->{'CONTAINER_ALIAS'};

    $kernel->yield ('componentProcessInput', $input);

$self->{'DEBUG'} && $kernel->post ($container, $logHandler, Dumper $input);
}

#
# Does input processing and dispatches the command (e.g. applies the context) 
sub componentProcessInputHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];
	my $self = $heap->{'self'};	

    my $logHandler = $self->{'LOG_HANDLER'};
    my $container = $self->{'CONTAINER_ALIAS'};

    $self->{'DEBUG'} && $kernel->post($container, $logHandler, Dumper $input);   	 

    if ($input->{'command'} eq 'redirect')
    {
        # call redirector 
        $kernel->yield ('componentRedirect', $input); 
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
    }
    elsif ($input->{'command'} eq 'applyContext')
    {
        # call the apply context handler
        $kernel->yield ('componentApplyContext', $input);
        # log 
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'}. ' from '. $input->{'from'});
        
    }
    elsif ($input->{'command'} eq 'noContext')
    {
        $kernel->yield('componentLogMsg', 'Got \'noContext\' from '. $input->{'from'}); 
        $kernel->yield('_stop');#exit;
    }
    else 
    {   
        #$kernel->yield('componentLogMsg', 'Got unknown command. The message was\n'. Dumper($input));
    }
}

#
# Asks a context

sub componentGetContextHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $contextID  = $self->{'CONTEXT_ID'};
    my $contextKey = $self->{'CONTEXT_KEY'}; 

    my $hostname = `hostname -f`;
    chomp $hostname;     

    my $ip = `/sbin/ip addr show`;
    chomp $ip;
   
    my $contextRequest = {  
                           'to'   => $self->{'CONTEXT_MANAGER_ADDRESS'},
                           'info' =>
                                     {
                                       'command'   => 'getContext',
                                       'contextID' => $contextID,
                                       'contextKey' => $contextKey,
                                       'agentHost' => $hostname, 
                                       'agentIP'   => $ip,
                                     },
                         };  
                    
    $kernel->yield ('componentLogMsg', 'Asking '. $self->{'CONTEXT_MANAGER_ADDRESS'}.' for the context');
    $kernel->post ($container, $sendHandler, $contextRequest);
}

sub componentApplyContextHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};
                    
    #$kernel->yield ('componentLogMsg', 'Got '. Dumper ($input) .' as a context');
    my $apiVersion;        

    $apiVersion = `python -c 'from amiconfig.instancedata import InstanceData;print InstanceData().apiversion' 2>&1`;
    $? or $apiVersion = '2007-12-15';
    my $dir = $self->{'CONTEXT_AGENT_WORKDIR'}.'/'.Copilot::GUID->CreateGuid().'/';  
   `mkdir -p $dir/$apiVersion`;

    my $context = "[cernvm]\n";
    foreach my $line (split('###', $input->{'context'}))
    {
        next unless $line =~ /^(\S+?)=(\S+)$/; # We do ungreedy matching since Base64 encoded strings are likely to contain = sign 
      
        if ($1 eq 'other')
        {	
            $line = decode_base64 ($2); 
        }		
        else
        {
            $line = "$1=".decode_base64($2);
        }
        

        $context .= "$line\n";
    }

    open FH, "> $dir/$apiVersion/user-data";
    print FH $context;
    close FH;

    $heap->{'currentContextWorkDir'} = $dir;

    $kernel->yield ('componentLogMsg','The context has been saved in '.$dir.$apiVersion.'/user-data file.');
    $kernel->yield ('componentStartAmiconfig');
}

sub componentStartAmiconfigHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    $kernel->yield ('componentLogMsg','Starting amiconfig');

    #my ( $kernel, $heap) = @_[ KERNEL, HEAP ];
    #
    #my $jobID = $heap->{'currentJobID'};
    #my $job = $heap->{$jobID}->{'job'};
    #
    #my $wrapper = $job->{'wrapper'};
    #my $workDir = $heap->{$jobID}->{'workdir'};   
    #
    #my $cmd = "cd $workDir && chmod a+x $wrapper && . $wrapper";
    
    $kernel->sig(CHLD => 'contextWheelFinished');
    my $dir = $heap->{'currentContextWorkDir'};
 
    # create stdout, stderr and resources files in working directory of the job
    # beacuse AliEn expects them to be there
    #my $wd =  $heap->{$jobID}->{'workdir'};
    #system ("touch $wd/stdout $wd/stderr $wd/resources"); 
    
    $heap->{'wheel'} = POE::Wheel::Run->new(
                                             Program => "env EC2_INSTANCEDATA_URL=file:$dir /usr/sbin/amiconfig ",    
                                             StdoutEvent  => 'contextWheelStdout',
                                             StderrEvent  => 'contextWheelStderr',
                                             StdioFilter  => POE::Filter::Line->new(),
                                             StderrFilter => POE::Filter::Line->new(),
                                             ErrorEvent   => 'contextWheelError',
                                           ); 

    my $childPID =  $heap->{'wheel'}->PID;
    $heap->{'amiconfigPid'} = $childPID;
    $kernel->yield ('componentLogMsg', "amiconfig started (PID: $childPID)");   
}

#
# Event for logging sterr of amiconfig
sub contextWheelStderrHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];

    my $wd = $heap->{'currentContextWorkDir'};
    my $fh = $heap->{'AMICONFIG_STDERR_HANDLE'};

    unless (defined($fh))
    {
        open $fh, "> $wd/stderr";
        $heap->{'AMICONFIG_STDERR_HANDLE'} = $fh;
    }

    print $fh "$txt\n";
}

#
# Event for logging stdout of amiconfig 
sub contextWheelStdoutHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];

    my $wd = $heap->{'currentContextWorkDir'};
    my $fh = $heap->{'AMICONFIG_STDOUT_HANDLE'};

    unless (defined($fh))
    {
        open $fh, "> $wd/stderr";
        $heap->{'AMICONFIG_STDOUT_HANDLE'} = $fh;
    }

    print $fh "$txt\n";

}

#
# Event for handling amiconfig exit
sub contextWheelFinishedHandler
{
    my ($heap, $kernel, $childPID, $exitCode) = @_[HEAP, KERNEL, ARG1, ARG2 ];

    # close STDOUT and STDERR handles;
    my $fh = $heap->{'AMICONFIG_STDOUT_HANDLE'};
    $fh and close $fh;

    $fh = $heap->{'AMICONFIG_STDERR_HANDLE'};
    $fh and close $fh;

    $kernel->yield('componentLogMsg', "Execution of child process (PID: $childPID) finished with \'$exitCode\'");

    # destroy the wheel
    delete $heap->{'wheel'};

	if ($exitCode == 0 && -e '/etc/init.d/cernvm')
	{   
        $kernel->yield('componentLogMsg', 'Restarting cernvm service');
        system("/etc/init.d/cernvm restart && wait");
	}

	if ($exitCode == 0 && -e '/etc/init.d/cvmfs')
	{   
        $kernel->yield('componentLogMsg', 'Restarting cvmfs service');
        system("/etc/init.d/cvmfs restart && wait");
	}

    $kernel->yield('_stop');
}

#
# Event for handling amiconfig errors 
sub contextWheelErrorHandler
{
    my ( $kernel, $operation, $code, $msg, $handle ) = @_[ KERNEL, ARG0, ARG1, ARG2, ARG4 ];

    if ( ($operation eq 'read') and ($code == 0) and ($handle eq 'STDERR' or $handle  eq 'STDOUT') and ($msg eq'') )
    { 
        return; # this situation is normal
    } 
    else
    {
        $kernel->yield('componentLogMsg', "Failed to $operation: $msg (Error code: $code). Handle: $handle");
    }
}


#
# Event which gets the log message and sends it to the container (server)
sub componentLogMsgHandler
{
    my ( $kernel, $heap, $msg, $logLevel) = @_[ KERNEL, HEAP, ARG0, ARG1];

    $logLevel or ($logLevel = 'info');
    
    my $self = $heap->{'self'};

    my $logHandler = $self->{'LOG_HANDLER'};
    my $container = $self->{'CONTAINER_ALIAS'};

    $kernel->post ($container, $logHandler, $msg, $logLevel);
}

#
# Method for redirection of the request
sub componentRedirectHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};

    my $sendHandler = $self->{'SEND_HANDLER'};


    my $data = $input->{'info'};
    my $to = $input->{'referral'};
    
    
    my $command = $data->{'command'};
    
    my $forwardRequest = {  
                            'to'   => $to,
                            'info' => $data,
                         };  
                    
    $kernel->yield ('componentLogMsg', 'Bouncing '. $command .' to '. $to );    
    $kernel->post ($container, $sendHandler, $forwardRequest); 
}
 

"M";
