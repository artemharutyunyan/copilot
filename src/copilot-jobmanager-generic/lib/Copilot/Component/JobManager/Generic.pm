package Copilot::Component::JobManager::Generic;

=head1 NAME Copilot::Component::JobManager::Generic

=head1 DESCRIPTION

This class implements the JobManager of the Copilot system for Generic. It is a child class of Copilot::Component (for general information
about the components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within one of
the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during
instantiation via 'ComponentOptions' parameter:

    ChirpDir               - Directory where the job manager should put the job files and create chirp access control list
                             files, so the agents can access them
    StorageManagerAddress  - The address (Jabber ID) of the storage manager where some of the requests are redirected

    Example of JobManager instantiation:
    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'JobManager::Generic',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                MonitorAddress => $monitorAddress,
                                                ComponentOptions => {
                                                                    ChirpDir => $chirpWorkDir ,
                                                                    StorageManagerAddress => $storageManagerJID,
                                                                  },
                                                Plugins => {
                                                             SystemMonitor => {},
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
use Copilot::Util;
use Copilot::GUID;

use POE;
use POE::Component::Logger;

use Data::Dumper;

use Redis;

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
    my $inputHandler = $self->{'COMPONENT_INPUT_HANDLER'};
    POE::Session->create (
                            inline_states => {
                                                _start                          => \&mainStartHandler,
                                                _stop                           => \&mainStopHandler,
                                                $inputHandler                   => \&componentInputHandler,
                                                componentProcessInput           => \&componentProcessInputHandler,
                                                componentStoreJob               => \&componentStoreJobHandler,
                                                componentWantGetJob             => \&componentWantGetJobHandler,
                                                componentGetJob                 => \&componentGetJobHandler,

                                                componentGetJobOutputDir        => \&componentGetJobOutputDirHandler,
                                                componentWantGetJobOutputDir    => \&componentWantGetJobOutputDirHandler,

                                                componentError                  => \&componentErrorHandler,
                                                componentNoJob                  => \&componentNoJobHandler,
                                                componentSendJob                => \&componentSendJobHandler,
                                                #componentSaveJob               => \&componentSaveJobHandler,
                                                componentJobDone                => \&componentJobDoneHandler,

                                                componentReportJobQueueStatus    => \&componentReportJobQueueStatus,
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
    $self->{'JOB_WORKDIR'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpDir'} || die "Chirp server directory is not provided.\n");

    # Event in server, which handles the messages sent from component to the outer world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n";

    # Event in parent class which handles forwarding the event data to monitoring component
    ($self->{'MONITOR_HANDLER'}         = $options->{'MONITOR_HANDLER'}       || die "MONITOR_HANDLER is not specified. Can't talk with the Monitor.\n");
    ($self->{'MONITOR_VALUE_HANDLER'}   = $options->{'MONITOR_VALUE_HANDLER'} || die "MONITOR_VALUE_HANDLER is not specified.\n");
    ($self->{'TIMING_START_HANDLER'}    = $options->{'TIMING_START_HANDLER'}  || die "TIMING_START_HANDLER is not specified.\n");
    ($self->{'TIMING_STOP_HANDLER'}     = $options->{'TIMING_STOP_HANDLER'}   || die "TIMING_STOP_HANDLER is not specified.\n");

    # Storage manager to redirect output requests to
    $self->{'STORAGE_MANAGER_ADDRESS'} = ($options->{'COMPONENT_OPTIONS'}->{'StorageManagerAddress'} or die "Storage manager address is not given.\n");

    # Chirp
    $self->{'CHIRP_HOST'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpServer'} || die "Chirp server address is not provided.\n");
    $self->{'CHIRP_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpPort'}   || die "Chirp port is not provided.\n");

    # Redis
    $self->{'REDIS_HOST'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisServer'} || die "Redis server address is not provided\n");
    $self->{'REDIS_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisPort'}   || die "Redis port address is not provided\n");

    # Done jobs dir
    $self->{'DONE_JOB_DIR'} = ($options->{'COMPONENT_OPTIONS'}->{'DoneJobDir'} || undef);
    $self->{'DONE_JOB_DIR'} = $self->{'DONE_JOB_DIR'}.'/' if defined $self->{'DONE_JOB_DIR'};

    # Waiting jobs list name
    $self->{'WAITING_JOBS_LIST'} = ($options->{'COMPONENT_OPTIONS'}->{'WaitingJobsList'} || 'waiting_jobs');

    # Require that a file exists before sending a job
    $self->{'JOB_REQUIRE_FILE'} = ($options->{'COMPONENT_OPTIONS'}->{'JobRequireFile'} || undef);
  
    # Check if 'storage-only' mode is on 
    $self->{'STORAGE_ONLY_ON'} = ($options->{'COMPONENT_OPTIONS'}->{'StorageOnlyOn'} || undef);

    # Check is 'queue-only' mode is on
    $self->{'QUEUE_ONLY_ON'} = ($options->{'COMPONENT_OPTIONS'}->{'QueueOnlyOn'} || undef);
}

#
# Called before the session is destroyed
sub mainStopHandler
{
    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    print "Stop has been called\n";

    # Lets monitor know that this agent is going offline
    # $kernel->yield('componentStopTimingEvent', 'session', 'session');
}

#
# Called before session starts
sub mainStartHandler
{
    my ( $kernel, $heap, $self) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{'self'} = $self;

    $kernel->alias_set ($self->{'COMPONENT_NAME'});

    # disabled until a proper exit handling is implemented
    #$kernel->yield('componentStartTimingEvent', 'session', 'session');

    # The number of jobs and system status in the queue will be reported every 60 seconds (after the initial report)
    $kernel->delay (componentReportJobQueueStatus => 60);
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
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $logHandler = $self->{'LOG_HANDLER'};
    my $container = $self->{'CONTAINER_ALIAS'};

    $kernel->yield ('componentProcessInput', $input);
#    $kernel->post ($container, $logHandler, $input);
}

#
# Does input processing and dispatches the command
sub componentProcessInputHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $jobID = $input->{'jobID'};

    if ($input->{'command'} eq 'storeJob')
    {
        $kernel->yield('componentStoreJob', $input);
        $kernel->post ($container, $logHandler, 'Got job submission');
    }
    elsif ($input->{'command'} eq 'want_getJob')
    {
        if ($self->{'STORAGE_ONLY_ON'}) 
        {
          $kernel->post ($container, $logHandler, 'Ignored the "want_getJob" request (StorageOnlyMode enabled)', 'debug');
          return;
        }
        $kernel->yield('componentWantGetJob', $input);
        $kernel->post ($container, $logHandler, 'Got the "want_getJob" request');
    }
    elsif ($input->{'command'} eq 'getJob')
    {
        if ($self->{'STORAGE_ONLY_ON'}) 
        {
          $kernel->post ($container, $logHandler, 'Ignored the "getJob" request (StorageOnlyMode enabled)', 'debug');
          return;
        }

        $kernel->yield('componentGetJob', $input);
        $kernel->post ($container, $logHandler, 'Got the real job request');
    }
    elsif ($input->{'command'} eq 'want_getJobOutputDir')
    {
        if ($self->{'QUEUE_ONLY_ON'}) 
        {
          $kernel->post ($container, $logHandler, 'Ignored the "want_getJobOutputDir" request (QueueOnlyMode enabled)', 'debug');
          return;
        }

        $kernel->yield('componentWantGetJobOutputDir', $input);
        $kernel->post ($container, $logHandler, 'Got the "want_getJobOutputDir" request.');
    }
    elsif ($input->{'command'} eq 'getJobOutputDir')
    {
        if ($self->{'QUEUE_ONLY_ON'}) 
        {
          $kernel->post ($container, $logHandler, 'Ignored the "getJobOutputDir" request (QueueOnlyMode enabled)', 'debug');
          return;
        }

        $kernel->yield('componentGetJobOutputDir', $input);
        $kernel->post ($container, $logHandler, "Agent asking for the output dir for the job (ID: $jobID)");
    }
    elsif ($input->{'command'} eq 'jobDone')
    {
        $kernel->yield('componentJobDone', $input);
        $kernel->post ($container, $logHandler, "Agent finished the job (ID: $jobID)");
    }
}

sub componentStoreJobHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];
    my $self = $heap->{'self'};
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

	# Create output directory for the job
	my $jobOutDir = $self->{'JOB_WORKDIR'}."/".$jobID;
	`mkdir -p $jobOutDir`;
	`echo -e "hostname:* rwl\naddress:* rwl\n" > $jobOutDir/.__acl`;
    `chmod -R a+rw $jobOutDir`;
	$kernel->post ($container, $logHandler, 'Created output directory for the job (Job ID: '. $jobID .')'. $jobOutDir );

	# Send the output dir back
	my $to = $input->{'from'};
    my $outputDir = {
                        'to' => $to,
                        'info' => {
                                    'command' => 'storeJobOutputDir',
                                    'outputDir' => $jobID,
                                    'outputChirpUrl' => $self->{'CHIRP_HOST'}.':'.$self->{'CHIRP_PORT'},
                                    'jobID' => $jobID,
                                  }
                    };
    #$kernel->post ($container, 'logstalgia', $input->{'from'}, 'getJobOutputDir', 'storeJobOutputDir', 100);
    $kernel->post ($container, $logHandler, 'Sending output directory for the job (ID: '.$jobID.') to '. $to );
    defined ($input->{'send_back'}) and ($outputDir->{'send_back'} =  $input->{'send_back'});
    $kernel->post ($container, $sendHandler, $outputDir);
}


#
# Internal function which finalizes the job execution (changes job status, uploads files)
sub componentJobDoneHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $container           = $self->{'CONTAINER_ALIAS'};
    my $logHandler          = $self->{'LOG_HANDLER'};
    my $sendHandler         = $self->{'SEND_HANDLER'};
    my $reportValueHandler  = $self->{'MONITOR_VALUE_HANDLER'};

    my $jobID       = $input->{'jobID'};
    my $exitCode    = $input->{'exitCode'} + 0;
    my $jmJobData   = Copilot::Util::stringToHash ($input->{'jmJobData'}) if defined ($input->{'jmJobData'});
    my $finishedAt  = time ();

    $kernel->post ($container, $logHandler, "Job $jobID has been completed");

    #$kernel->post($container, 'logstalgia', $input->{'from'}, 'jobDone', 'Bravo!', 100);

    my $doneJobDir = $self->{'DONE_JOB_DIR'};
    if (defined $doneJobDir)
    {
        my $jobOut = $self->{'JOB_WORKDIR'}.'/'.$jobID;
        my @timeArray = localtime();

        my $year = $timeArray[5] + 1900;
        my $mon  = sprintf("%02d", $timeArray[4] + 1);
        my $mday = sprintf("%02d", $timeArray[3]);

        my $todayDir = $doneJobDir.'/'.$year.$mon.$mday;
        `mkdir -p $todayDir`;

        # Due to a bug in chirp we have to copy .__acl file from parent dir
        my $chirpAcl = "$doneJobDir/.__acl";
        `cp $chirpAcl $todayDir` if -e $chirpAcl;

        my $cmd = "mv $jobOut/$jobID".".tgz $todayDir";
        `$cmd`;
        $kernel->post ($container, $logHandler, "Executing $cmd.", 'debug');

        $cmd = "chmod a+rw $todayDir"."/"."$jobID".".tgz";
        `$cmd`;
        $kernel->post ($container, $logHandler, "Executing $cmd.", 'debug');

        $kernel->post ($container, $logHandler, "Moving output of the job (ID: $jobID).", 'info');
    }
    else
    {
        $kernel->post ($container, $logHandler, "DoneJobDir is not defined. Not moving the job output");
    }

    my $jobDuration = $finishedAt - ($jmJobData->{'startedAt'} || $finishedAt);
    my $jobStatus   = ($exitCode == 0) ? 'succeeded' : 'failed';
    $kernel->post ($container, $reportValueHandler, "job.$jobStatus", $jobDuration, 'duration'); 
}

#
# Tries to scoop the agent for sending the output directory
sub componentWantGetJobOutputDirHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $info = {
                'to'   => $input->{'from'},
                'info' => {
                            'command' => 'have_getJobOutputDir',
                          },
                };

    defined ($input->{'send_back'}) and ($info->{'send_back'} = $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Sending "have_getJobOutputDir" to '.$input->{'from'});
    $kernel->post ($container, $sendHandler, $info);
    #$kernel->post($container, 'logstalgia', $input->{'from'}, 'want_getJobOutputDir', 'have_getJobOutputDir', 100);
}

#
# Tries to scoop the agent for sending job
sub componentWantGetJobHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];
    my $self = $heap->{'self'};

    my $container           = $self->{'CONTAINER_ALIAS'};
    my $logHandler          = $self->{'LOG_HANDLER'};
    my $sendHandler         = $self->{'SEND_HANDLER'};
    my $reportEventHandler  = $self->{'MONITOR_HANDLER'};

    my $r = Redis->new(server => $self->{'REDIS_HOST'}.":".$self->{'REDIS_PORT'});

    my $f; 
    ($f, undef) = split ('@', $input->{'from'});

    #$self->{'agentList'} = {} if not defined ($self->{'agentList'});
    #my $lastSeen = $self->{'agentList'}->{$input->{'from'}};
    my $lastSeen = $r->get("agentseen::".$f);
    my $t = time();

    if (defined ($lastSeen) and ($t - $lastSeen) < 60) 
    {   
        $kernel->post($container, $logHandler, "Agent ".$input->{'from'}." sending job requests way to often. Putting bastard to sleep.", 'info');
     
        my $info = { 
                    'to'   => $input->{'from'},
                    'info' => { 
                                'command' => 'sleep',
                              },
                   };
    
        #$kernel->post($container, 'logstalgia', $input->{'from'}, 'want_getJob', 'sleep', 100);
        defined ($input->{'send_back'}) and ($info->{'send_back'} =  $input->{'send_back'});
        $kernel->post ($container, $sendHandler, $info);  
        return;
    }   

    #$self->{'agentList'}->{$input->{'from'}} = $t;
    $r->set("agentseen::".$f, $t);

    my $waitingJobsList = $self->{'WAITING_JOBS_LIST'};
    my $nWaitingJobs    = $r->llen($waitingJobsList);

    $kernel->post($container, $logHandler, "The queue has $nWaitingJobs waiting job(s).", 'debug');

    if ($nWaitingJobs > 0)
    {
        my $info = {
                    'to'   => $input->{'from'},
                    'info' => {
                                'command' => 'have_getJob',
                              },
                   };

        # If set by config require a file to exist on agent side
        $info->{'info'}->{'requireFile'} = $self->{'JOB_REQUIRE_FILE'} if ($self->{'JOB_REQUIRE_FILE'});

        # see if there is something we need to pass back to the container
        defined ($input->{'send_back'}) and ($info->{'send_back'} =  $input->{'send_back'});

        $kernel->post ($container, $logHandler, "Sending 'have_getJob' to " .$input->{'from'} .". Have $nWaitingJobs job(s) waiting in the queue.");
        $kernel->post ($container, $sendHandler, $info);

        #$kernel->post($container, 'logstalgia', $input->{'from'}, 'want_getJob', 'have_getJob', 100);
    }
    else
    {
        $kernel->post($container, $logHandler, 'The queue is empty. Not sending have_getJob.');
        $kernel->post($container, $reportEventHandler, 'error.emptyQueue');
        #$kernel->post($container, 'logstalgia', $input->{'from'}, 'want_getJob', 'noJob', 100);
    }
}

#
# Internal function which tries to get a job
sub componentGetJobHandler
{
    my ($heap, $kernel, $input) = @_[ HEAP, KERNEL, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};
    my $reportEventHandler = $self->{'MONITOR_HANDLER'};

    my $waitingJobsList = $self->{'WAITING_JOBS_LIST'};

    my $r = Redis->new(server=> $self->{'REDIS_HOST'}.":".$self->{'REDIS_PORT'});
    my $jobGuid = $r->lpop ($waitingJobsList);

    if ($jobGuid)
    {
        my $key = "job:$jobGuid:description";
        my $desc = $r->get($key);

        my $job = {};
        $job->{'id'} = $jobGuid;

        if (! $desc)
        {
            $kernel->post ($container, $logHandler, 'Got job with ID '. $job->{'id'} ," the entry $key did not exist", 'error');
            $kernel->post ($container, $reportEventHandler, 'error.invalidJobId');
            return;
        }

        ($job->{'chirpUrl'},
         $job->{'inputDir'},
         $job->{'inputFiles'},
         $job->{'command'},
         $job->{'arguments'},
         $job->{'environment'},
         $job->{'packages'} ) = split ('::::', $desc);

        $kernel->post ($container, $logHandler, 'Got job with ID '. $job->{'id'});
        $kernel->yield ('componentSendJob', $input, $job);
    }
    else
    {
        $kernel->post($container, $logHandler, 'Got getJob request but the queue was empty.');
        $kernel->post($container, $reportEventHandler, 'error.emptyQueue');
        #$kernel->post($container, 'logstalgia', $input->{'from'}, 'getJob', 'noJob', 100);
    }
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
#sub componentSaveJobHandler
#{
#    my ($heap, $kernel, $jobHandle, $agentRequest, $jobInfo) = @_[ HEAP, KERNEL, ARG0, ARG1, ARG2 ];
#
#    my $self = $heap->{'self'};
#
#    my $container = $self->{'CONTAINER_ALIAS'};
#    my $logHandler = $self->{'LOG_HANDLER'};
#
#    my $jobID = $jobInfo->{'id'};
#    $kernel->post ($container, $logHandler, 'Saving the handle of the job '. $jobInfo->{'id'});
#
#    $heap->{$jobID} = {};
#    $heap->{$jobID}->{'handle'} = $jobHandle;
#}

#
# Internal function for sending jobs to agents
sub componentSendJobHandler
{
    my ($heap, $kernel, $input, $jobInfo) = @_[ HEAP, KERNEL, ARG0, ARG1 ];

    my $self = $heap->{'self'};

    my $container           = $self->{'CONTAINER_ALIAS'};
    my $logHandler          = $self->{'LOG_HANDLER'};
    my $sendHandler         = $self->{'SEND_HANDLER'};
    my $reportEventHandler  = $self->{'MONITOR_HANDLER'};


    # Send the job to the agent
    my $jmJobData = {
                        'startedAt' => time (),
                    };

    my $job = {
                'to'   => $input->{'from'},
                'info' => {
                            'command'   => 'runJob',
                            'job'       => $jobInfo,
                            'jmJobData' => Copilot::Util::hashToString ($jmJobData),
                          },
              };

    # see if there is something we need to pass back to the container
    defined ($input->{'send_back'}) and ($job->{'send_back'} =  $input->{'send_back'});

    $kernel->post ($container, $logHandler, 'Sending job with ID '. $jobInfo->{id} .' for execution to '.$input->{'from'});
    $kernel->post ($container, $sendHandler, $job);
    $kernel->post ($container, $reportEventHandler, 'job.start');
    #$kernel->post($container, 'logstalgia', $input->{'from'}, 'getJob', 'runJob', 100);
}

sub componentReportJobQueueStatus
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $reportValueHandler = $self->{'MONITOR_VALUE_HANDLER'};

    my $r = Redis->new(server=> $self->{'REDIS_HOST'}.":".$self->{'REDIS_PORT'});
    my $waitingJobsList = $self->{'WAITING_JOBS_LIST'};
    my $jobsN = $r->llen($waitingJobsList);

    $kernel->post($container, $reportValueHandler, 'queuedJobs', $jobsN);

    $kernel->delay(componentReportJobQueueStatus => 60);
}

"M";
