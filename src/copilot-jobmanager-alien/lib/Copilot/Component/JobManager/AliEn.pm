package Copilot::Component::JobManager::AliEn;

=head1 NAME Copilot::Component::JobManager::AliEn

=head1 DESCRIPTION

This class implements the JobManager of the Copilot system for AliEn. It is a child class of Copilot::Component (for general information 
about the components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within one of 
the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during 
instantiation via 'ComponentOptions' parameter:

    ChirpDir               - Directory where the job manager should put the job files and create chirp access control list 
                             files, so the agents can access them
    AliEnUser              - AliEn system username, which will be used to connect to AliEn components to retireve jobs
    StorageManagerAddress  - The address (Jabber ID) of the storage manager where some of the requests are redirected 

    Exmaple of JobManager instantiation:
    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'JobManager',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ComponentOptions => {
                                                                    ChirpDir => $chirpWorkDir ,
                                                                    AliEnUser => 'hartem',
                                                                    StorageManagerAddress => $storageManagerJID,
                                                                  },
                                                SecurityModule => 'Provider',
                                                SecurityOptions => {
                                                                    KMAddress => $keyServerJID,
                                                                    PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                    ComponentPublicKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.pub', 
                                                                    ComponentPrivateKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.priv', 
                                                                   },                 
                                            }
                                        ); 

=cut


use strict;
use warnings;

use vars qw (@ISA);
our $VERSION="0.01";

use Copilot::Component;

use POE;
use POE::Component::Logger;
use Copilot::Classad::Host::AliEn;
use AliEn::Service;


use Data::Dumper;

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
                                                $self->{'COMPONENT_INPUT_HANDLER'} => \&componentInputHandler,
                                                componentProcessInput => \&componentProcessInputHandler,
                                                componentGetJob => \&componentGetJobHandler,
                                                componentGetJobOutputDir => \&componentGetJobOutputDirHandler,
                                                componentError => \&componentErrorHandler,
                                                componentNoJob => \&componentNoJobHandler,
                                                componentSendJob => \&componentSendJobHandler,
                                                componentSaveJob => \&componentSaveJobHandler,
                                                componentJobDone => \&componentJobDoneHandler,
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
        or die "CONTAINER_ALIAS is not specified. Can't communicate with server\n";
   
    # Event, which handles server input inside the component
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentHandleInput';    

    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger'); 

    # Working directory directory on the server 
    $self->{'JOB_WORKDIR'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpDir'} || die "Chirp server directory is not provided. Can not start the job manager.\n"); 

    # AliEn username
    $self->{'ALIEN_USER'} = ($options->{'COMPONENT_OPTIONS'}->{'AliEnUser'} || $ENV{USER} );

    # Event in server, which handles the messages sent from component to the outer world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n"; 

    # Storage manager to redirect output requests to
    $self->{'STORAGE_MANAGER_ADDRESS'} = ($options->{'COMPONENT_OPTIONS'}->{'StorageManagerAddress'} or die "Storage manager address is not given.\n");         
}

#
# Called before the session is destroyed
sub mainStopHandler
{
    print "Stop has been called\n";
}

#
# Called before session starts 
sub mainStartHandler
{

    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;
   
    $kernel->alias_set ($self->{'COMPONENT_NAME'});

#    $_[SESSION]->option (trace => 1);
}


#
# Returns the name of input handler 
sub getInputHandler
{ 
    my $self = shift;
    return $self->{'COMPONENT_INPUT_HANDLER'}; 
}

#
# Handles input from server 
sub componentInputHandler
{
   my ($kernel, $input) = @_[KERNEL, ARG0 ];
   $kernel->yield ('componentProcessInput', $input);
}

#
# Does input processing and dispatches the command 
sub componentProcessInputHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    if ($input->{'command'} eq 'getJob')
    {
        $kernel->post ($container, $logHandler, 'Got job request');
        $kernel->yield ('componentGetJob', $input);
    }
    if ($input->{'command'} eq 'getJobOutputDir')
    {
        my $jobID = $input->{'jobID'};
        $kernel->post  ($container, $logHandler, "Agent asking for the output dir for the job (ID: $jobID)");
        $kernel->yield ('componentGetJobOutputDir', $input);
    }
    elsif ($input->{'command'} eq 'jobDone')
    {
        my $jobID = $input->{'jobID'};
        $kernel->post ($container, $logHandler, "Agent finished the job (ID: $jobID)");
        $kernel->yield ('componentJobDone', $input);
    }
    

}

#
# Internal function which gets output dir for the job (redirects the agent to the storage manager)
sub componentGetJobOutputDirHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};
        
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jobID = $input->{'jobID'};
    my $agentHost = $input->{'agentHost'};

    my $adapter = $heap->{$jobID}->{'handle'};

    #
    # Monitor causes problems during deserialization
    delete ($adapter->{'MONITOR'});    


    my $localLog = $adapter->{'LOGFILE'};
    open FH, "< $localLog";
    my $jobLogFile = join ('', <FH>);
    close FH; 
   
    my $storageRef = {
                        'to'   => $input->{'from'},
                        'info' => {
                                    'command' => 'redirect',
                                    'referral' => $self->{'STORAGE_MANAGER_ADDRESS'},  
                                    'info'    => {  
#                                                   'referral' => $self->{'STORAGE_MANAGER_ADDRESS'},  
                                                    'adapter'  => {
                                                                    'WORKDIR' => $adapter->{'WORKDIR'},
                                                                    'CA' => $adapter->{'CA'}->asJDL(),
                                                                    'ENV' => $adapter->{'ENV'},
                                                                    'VOs' => $adapter->{'VOs'},
                                                                    'STATUS' => $adapter->{'STATUS'},
                                                                    'WORKDIR_RELATIVE_PATH' => $adapter->{'WORKDIR_RELATIVE_PATH'},
                                                                    'JA_LOG_CONTENT' => $jobLogFile,
                                                                  }, 
                                                    'jobID'    => $jobID,
                                                    'command'  => 'getJobOutputDir',
                                                    'agentHost' => $agentHost,
                                                 },     
                                  }, 
                     };   
    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($storageRef->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Redriecting jobagent (Job ID: '. $jobID .' to the storage manager ('. $self->{'STORAGE_MANAGER_ADDRESS'}.')' );
    $kernel->post ($container, $sendHandler, $storageRef);    
}
    

#
# Internal function which finalizes the job execution (changes job status, uploads files)
sub componentJobDoneHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jobID = $input->{'jobID'};

    # add redirection information
    #   $input->{'referral'} = $self->{'STORAGE_MANAGER_ADDRESS'};   
   
    my $to = $input->{'from'};
    delete ($input->{'from'});    
    
    my $storageRef = {
                        'to'   => $to,
                        'info' => {
                                    'command'  => 'redirect',
                                    'referral' => $self->{'STORAGE_MANAGER_ADDRESS'}, 
                                    'info'     => $input,     
                                  }, 
                     };   
    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($storageRef->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Redriecting jobagent (Job ID: '. $jobID .' to the storage manager ('. $self->{'STORAGE_MANAGER_ADDRESS'}.')' );
    $kernel->post ($container, $sendHandler, $storageRef);              
}

#
# Internal function which tries to get a job
sub componentGetJobHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    my $options = {
                    'debug' => 0,
                    'user'  => $self->{'ALIEN_USER'},
                  };

    # Append AliEn specific information to the JDL
    my $jdl = new Copilot::Classad::Host::AliEn ($input->{'jdl'});
   
    $options->{'jdl'} = $jdl->asJDL();  
   
    # Set the working directory 
    $options->{'workdir'} = $self->{'JOB_WORKDIR'};

    # Try to get a job from AliEn task queue
    use AliEn::Service;
    my $name = "AliEn::Service::JobAgent::Adapter";
    eval "require $name";
   
    if ($@)  # failed to load adapter module
    {
        $kernel->post ($container, $logHandler, "Failed to load $name: $@", 'error');
        $kernel->yield ('componentError');
        return; 
    }

    $ENV{ALIEN_JOBAGENT_ID} = $$;

    $options->{'debug'}=10;

    my $adapter = $name->AliEn::Service::new ($options);  
    $kernel->post ($container, $logHandler, 'Sending job request.', '');
    my $job = $adapter->getJob();

    if (! $job->{command}) # we did not get the job. do something !
    {
        $kernel->yield ('componentNoJob');
        $kernel->post ($container, $logHandler, 'Got no job.');
        return;
    }

    $kernel->post ($container, $logHandler, 'Got job with ID '. $job->{'id'});

    # OK. We have the job now. We have to create chirp ACL entry in workdir
    # $adapter->createChirpACL ("hostname:". $input->{'agentHost'} ." rwl");
    $adapter->createChirpACL ("hostname:* rwl");

    $kernel->yield ('componentSaveJob', $adapter, $input, $job);
    $kernel->yield ('componentSendJob', $input, $job);
}

#
# Internal function for error reporting 
sub componentErrorHandler
{

}

#
# Internal function for telling the agents that there is no job to execute
sub componentNoJobHandler
{
    my ( $heap, $kernel ) = @_[ HEAP, KERNEL ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    $kernel->post ($container, $logHandler, 'Did not get a job. Doing nothing.');
}

#
# Internal function for saving job's agent handler
sub componentSaveJobHandler
{
    my ($heap, $kernel, $jobHandle, $agentRequest, $jobInfo) = @_[ HEAP, KERNEL, ARG0, ARG1, ARG2 ];

    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    my $jobID = $jobInfo->{'id'};
    $kernel->post ($container, $logHandler, 'Saving the handle of the job '. $jobInfo->{'id'});

    $heap->{$jobID} = {};
    $heap->{$jobID}->{'handle'} = $jobHandle;
}

#
# Internal function for sending jobs to agents 
sub componentSendJobHandler
{
    my ($heap, $kernel, $input, $jobInfo) = @_[ HEAP, KERNEL, ARG0, ARG1 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

   
    # Send the job to the agent
    
    my $job = {
                'to'   => $input->{'from'},
                'info' => { 
                            'command' => 'runJob',
                            'job'     => $jobInfo,
                           },
                               
             };

    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($job->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Sending job with ID '. $jobInfo->{id} .' for execution to '.$input->{'from'});
    $kernel->post ($container, $sendHandler, $job);    
}


"M";
