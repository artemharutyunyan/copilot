package Copilot::Component::Agent;

=head1 NAME Copilot::Component::Agent

=head1 DESCRIPTION

This class implements the JobAgent of the Copilot system, it inherits from Copilot::Component (for general information
about the Components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within
one of the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during
instantiation via 'ComponentOptions' parameter:

    JMAddress - Address of the Job Manager component (can be either host:port combination or Jabber ID)
    WorkDir   - Temporary directory where the agent will keep files of the jobs

    Exmaple:

my $agent = new Copilot::Container::XMPP (
                                    {
                                      Component => 'Agent',
                                      LoggerConfig => $loggerConfig,
                                      JabberID => $jabberID,
                                      JabberPassword => $jabberPassword,
                                      JabberDomain => $jabberDomain,
                                      JabberServer => $jabberServer,
                                      ComponentOptions => {
                                                            JMAddress  => $JMAddress,
                                                            WorkDir => '/tmp/agentWorkdir',
                                               		  },
                                     SecurityModule => 'Consumer',
                                     SecurityOptions => {
                                                         KMAddress => $keyServerJID,
                                                         TicketGettingCredential => 'blah',
                                                         PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                        },

                                    }
                                  );


=cut


use POE;
use POE::Wheel::Run;

use vars qw (@ISA);
our $VERSION="0.01";

use Copilot::Component;
use Copilot::Classad::Host;

use strict;
use warnings;


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
                                                $self->{'COMPONENT_INPUT_HANDLER'} =>  \&componentInputHandler,
                                                $self->{'COMPONENT_WAKEUP_HANDLER'} => \&componentWakeUpHandler,
                                                componentProcessInput => \&componentProcessInputHandler,
                                                componentWantGetJob => \&componentWantGetJobHandler,
                                                componentGetJob => \&componentGetJobHandler,
                                                componentHaveGetJob => \&componentHaveGetJobHandler,
                                                componentStopWaitingJob => \&componentStopWaitingJobHandler,
                                                componentStartJob => \&componentStartJobHandler,
                                                componentDispatchJob => \&componentDispatchJobHandler,
                                                componentGetJobInputFiles => \&componentGetJobInputFilesHandler,
                                                    chirpGet => \&chirpGetHandler,
                                                    createJobWorkDir => \&createJobWorkDirHandler,
                                                componentCreateJobWrapper => \&componentCreateJobWrapperHandler,
                                                componentExecuteJobCommand => \&componentExecuteJobCommandHandler,
                                                    jobWheelFinished => \&jobWheelFinishedHandler,
                                                    jobWheelStdout => \&jobWheelStdoutHandler,
                                                    jobWheelStderr => \&jobWheelStderrHandler,
                                                    jobWheelError => \&jobWheelErrorHandler,
                                                componentValidateJob => \&componentValidateJobHandler,
                                                    validateWheelFinished => \&validateWheelFinishedHandler,
                                                    validateWheelStdout => \&validateWheelStdoutHandler,
                                                    validateWheelStderr => \&validateWheelStderrHandler,
                                                    validateWheelError => \&validateWheelErrorHandler,
                                                componentWantGetJobOutputDir => \&componentWantGetJobOutputDirHandler,
                                                componentGetJobOutputDir => \&componentGetJobOutputDirHandler,
                                                    storeOutputDir => \&storeOutputDirHandler,
                                                componentStopWaitingOutputDir => \&componentStopWaitingOutputDirHandler,
                                                componentPutJobOutputFiles => \&componentPutJobOutputFilesHandler,
                                                    chirpPut => \&chirpPutHandler,
                                                componentJobDone => \&componentJobDoneHandler,
                                                componentError => \&componentErrorHandler,
                                                componentLogMsg => \&componentLogMsgHandler,
                                                componentRedirect => \&componentRedirectHandler,

                                                componentSlp => \&componentSlpHandler,
                                                componentSleepReboot => \&componentSleepRebootHandler,
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
    $self->{'COMPONENT_INPUT_HANDLER'} = 'componentHandleInput';

    # Event, which handles wake up inside the component (called once, when client is connected to the component)
    $self->{'COMPONENT_WAKEUP_HANDLER'} = 'componentHandleWakeUp';

    # JM Host
    $self->{'JOB_MANAGER_ADDRESS'} = $options->{'COMPONENT_OPTIONS'}->{'JMAddress'};
    $self->{'JOB_MANAGER_ADDRESS'} or die "Job manager address is not provided.\n";

    # Agent workdir
    $self->{'AGENT_WORKDIR'} = $options->{'COMPONENT_OPTIONS'}->{'WorkDir'};
    $self->{'AGENT_WORKDIR'} || ( $self->{'AGENT_WORKDIR'} = '/tmp/agentWorkdir');

    # Event which handles log messages inside the server
    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger');


}

#
# Called before the session is destroyed
sub mainStopHandler
{
    die "Stop has been called\n";
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
   # Tell JM that we are up and ask for a job
   $kernel->yield ('componentWantGetJob');


   # Write to log file
   $kernel->yield ('componentLogMsg', "Component was waken up. Asking job manager for a job", 'info');

   $self->{'COMPONENT_HAS_JOB'} = 0;
   $self->{'COMPONENT_WAITING_JOB'} = 0;
   $self->{'COMPONENT_HAS_OUTPUT_DIR'} = 0;
   $self->{'COMPONENT_WAITING_OUTPUT_DIR'} = 0;
   $self->{'FAILED_REQ_COUNT'} = 0;
}

#
# Handles input from server
sub componentInputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('componentProcessInput', $input);
}

sub componentSlpHandler
{
    my ($kernel, $heap, $t)  = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};

    if ( $self->{'COMPONENT_HAS_JOB'} == 1)
    {
        $kernel->yield ('componentLogMsg', "Seem to have a job running. Not going to sleep", 'info');
        return;
    }

    $kernel->yield ('componentLogMsg', "Will sleep for $t seconds and reboot after wakeup.", 'info');
    $self->{'sleepTime'} = $t;
    $kernel->delay ('componentSleepReboot', 3);
}

sub componentSleepRebootHandler
{
    my $heap = $_[ HEAP ];
    my $self = $heap->{'self'};
    my $t = $self->{'sleepTime'};

     `wall The Agent is going to sleep`;
    sleep $t;
    `/usr/bin/reboot`;
}

#
# Does input processing and dispatches the command (e.g. starts job)
sub componentProcessInputHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];
	my $self = $heap->{'self'};

    if ($input->{'command'} eq 'error')
    {
        $kernel->yield('componentLogMsg', 'Got error:'. Dumper $input);
        $kernel->delay('componentError', 2);
        return;
    }

    if ($input->{'command'} eq 'redirect')
    {
        # call redirector
        $kernel->yield ('componentRedirect', $input);
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
	return;
    }

    if ($input->{'command'} eq 'sleep')
    {
        my $t = int(rand(1200));
        $kernel->yield ('componentLogMsg', 'Was gently asked to sleep for '. $t . ' seconds', 'info');
        $kernel->yield ('componentSlp', $t);
        return;
    }

    if ($heap->{'expectedCommand'} ne $input->{'command'})
    {
        $kernel->yield('componentLogMsg', 'Expected ' .$heap->{'expectedCommand'}. ' but got '. $input->{'command'} . '. Doing nothing', 'debug');
        return;
    }
    elsif ($input->{'command'} eq 'have_getJob')
    {
        # call the getJob Handler
        #$kernel->yield ('componentGetJob', $input->{'from'});
        $kernel->yield ('componentHaveGetJob', $input);
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'}. ' from '. $input->{'from'});
    }
    elsif ($input->{'command'} eq 'runJob')
    {
        $self->{'COMPONENT_HAS_JOB'} = 1;
        $self->{'COMPONENT_WAITING_JOB'} = 0;
        # prepare job data on the heap and pass control to the dispatcher function
        $kernel->yield('componentStartJob', $input);
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
        $heap->{'expectedCommand'} = 'have_getJobOutputDir';
    }
    elsif ($input->{'command'} eq 'have_getJobOutputDir')
    {
        # Request real job output directory
        $kernel->yield('componentGetJobOutputDir', $input->{'from'});
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
        $heap->{'expectedCommand'} = 'storeJobOutputDir';
    }
    elsif ($input->{'command'} eq 'storeJobOutputDir')
    {
        $self->{'COMPONENT_WAITING_OUTPUT_DIR'} = 0;
        # Store output dir and upload the files
        $kernel->yield('storeOutputDir', $input);
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
    }

}


#
# Asks for a job
sub componentWantGetJobHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    my $self = $heap->{'self'};

    $self->{'wantJobTrial'} = 1 if not defined($self->{'wantJobTrial'});

    # return if the agent has already beed loaded with the job
    if ($self->{'COMPONENT_HAS_JOB'} != 0 or $self->{'COMPONENT_WAITING_JOB'} != 0)
    {
        $kernel->yield ('componentLogMsg', 'Got reply for want_getJob. Purging previously scheduled requests.', 'info');
        return;
    }
    else
    {
        my $waitTime =  60 * $self->{'wantJobTrial'};
        $kernel->yield ('componentLogMsg', "Scheduling another want_getJob request in $waitTime seconds", 'info');
        $self->{'wantJobTrial'} *= 2;
        $kernel->delay ('componentWantGetJob', $waitTime );
        $self->{'wantJobTrial'} = 1 if $self->{'wantJobTrial'} > 60; # Reset the counter if we reached 1 hour
    }

    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jdl = new Copilot::Classad::Host();

    my $hostname = `hostname -f`;
    chomp $hostname;

    my $jobRequest = {
                        'to'   => $self->{'JOB_MANAGER_ADDRESS'},
                        'info' =>
                                  {
                                    'command'   => 'want_getJob',
                                    'jdl'       => $jdl->asJDL(),
                                    'agentHost' => $hostname, # needed to open access on chirp server
                                  },
                     };
    $heap->{'expectedCommand'} = 'have_getJob';
    $kernel->yield ('componentLogMsg', 'Asking '. $self->{'JOB_MANAGER_ADDRESS'}.' for an adress of the job manager');
    $kernel->post ($container, $sendHandler, $jobRequest);
}

sub componentHaveGetJobHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $requireFile = $input->{'requireFile'};
    my $from = $input->{'from'};

    my $self = $heap->{'self'};

    if (defined($requireFile))
    {
        $kernel->yield ('componentLogMsg', "Job manager ($from) requires $requireFile to be present. Doing the check.", 'info');

        if ( -e $requireFile)
        {
            $kernel->yield ('componentLogMsg', 'The file is present. Proceeding with the job request', 'info');
            $self->{'FAILED_REQ_COUNT'} = 0;
        }
        else
        {
            $self->{'FAILED_REQ_COUNT'}++;
            if ( $self->{'FAILED_REQ_COUNT'} > 3)
            {
                $kernel->yield( 'componentError', 'Failed to satisfy the requirement of the Job Manager for 3 consecutive times. Will sleep and reboot.');
                return;
            }

            $kernel->yield ('componentLogMsg', "The file $requireFile can not be found. want_getJob will be called automatically later.", 'info');
            return;
        }
    }

    $kernel->yield ('componentGetJob', $input->{'from'});
    $heap->{'expectedCommand'} = 'runJob';
}

sub componentGetJobHandler
{
    my ( $kernel, $heap, $jobManager) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};

    # return if the agent has already beed loaded with the job
    return if ($self->{'COMPONENT_HAS_JOB'} != 0 or $self->{'COMPONENT_WAITING_JOB'} != 0);

    $self->{'COMPONENT_WAITING_JOB'} = 1;
    $self->{'wantJobTrial'} = 1;
    $self->{'wantOutputDirTrial'} = 1;

    my $container = $self->{'CONTAINER_ALIAS'};

    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jdl = new Copilot::Classad::Host();

    my $hostname = `hostname -f`;
    chomp $hostname;

    my $jobRequest = {
                        'to'   => $jobManager,
                        'info' =>
                                  {
                                    'command'   => 'getJob',
                                    'jdl'       => $jdl->asJDL(),
                                    'agentHost' => $hostname, # needed to open access on chir server
                                  },
                     };

    $kernel->yield ('componentLogMsg', 'Asking '. $jobManager .' for a job');
    $kernel->yield ('componentLogMsg', 'Will wait for runJob for a minute.', 'debug');
    $kernel->post ($container, $sendHandler, $jobRequest);

    # We wait for 2 minutes then clear the waiting flag
    $kernel->delay('componentStopWaitingJob', 60);
}

sub componentStopWaitingJobHandler
{
    my ( $kernel, $heap, $jobManager) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};

    if ( $self->{'COMPONENT_WAITING_JOB'} == 1)
    {
        # Clear the waiting flag
        $self->{'COMPONENT_WAITING_JOB'} = 0;
        $kernel->yield('componentWantGetJob');
    }
    else
    {
        $kernel->yield ('componentLogMsg', 'Purging previously scheduled getJob request', 'debug');
    }
}

#
# This function prepares job data on the heap and passes control to the dispatcher
# which manges the job flow (fetches input files, executes the job command, sends files back
# etc).

sub componentStartJobHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];

    my $job = $input->{'job'};

    my $jobID = $job->{'id'};

    $kernel->yield ('componentLogMsg', 'Got job to run with ID '. $jobID);

    $heap->{$jobID} = {};
    $heap->{$jobID}->{'job'} = $job;
    $heap->{$jobID}->{'JobManagerAddress'} = $input->{'from'};
    $heap->{$jobID}->{'jmJobData'} = $input->{'jmJobData'} || undef;

    $heap->{$jobID}->{'state'} = 'prepare';
    $heap->{'currentJobID'} = $jobID;

    $kernel->yield ('componentDispatchJob');
}

#
# This is the function which controls the job flow.
sub componentDispatchJobHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    my $jobID = $heap->{'currentJobID'};
    my $prevState = $heap->{$jobID}->{'state'};

    if ($prevState eq 'prepare')
    {
        # job data is on the heap we start fetching files
        $heap->{$jobID}->{'state'} = 'getInput';
        $kernel->yield ('componentGetJobInputFiles');
    }
    elsif ($prevState eq 'getInput') # files are fetched we prepare job wrapper script
    {
        # create the wrapper
        $heap->{$jobID}->{'state'} = 'createWrapper';
        $kernel->yield ('componentCreateJobWrapper');
    }
    elsif ($prevState eq 'createWrapper') # files are fetched, wrapper is ready we start command execution
    {
        # start the command execution
        $heap->{$jobID}->{'state'} = 'execute';
        $kernel->yield ('componentExecuteJobCommand');
    }
    elsif ($prevState eq 'execute') #
    {
        # done execution, now we have to validateupload files
        $heap->{$jobID}->{'state'} = 'validate';
        $kernel->yield ('componentValidateJob');
    }
    elsif ($prevState eq 'validate') #
    {
        # done validation, now we have to get the directory to upload files
        $heap->{$jobID}->{'state'} = 'getOutputDir';
        $kernel->yield ('componentWantGetJobOutputDir');
    }
    elsif ($prevState eq 'getOutputDir')
    {
        # done getting the directory now we have to upload files
        $heap->{$jobID}->{'state'} = 'putOutput';
        $kernel->yield ('componentPutJobOutputFiles');
    }
    elsif ($prevState eq 'putOutput')
    {
        $heap->{$jobID}->{'state'} = 'ready';
        my $hostname = `hostname -f`;
        chomp $hostname;

        my $jobData = { 'state'     => $heap->{$jobID}->{'state'},
                        'exitCode'  => $heap->{$jobID}->{'exitCode'},
                        'jobID'     => $jobID,
                        'agentHost' => $hostname,
                      };

        if ( $heap->{$jobID}->{'job'}->{'validationScript'} )
        {
            $jobData->{'validateExitCode'} = $heap->{$jobID}->{'validateExitCode'};
        }

        if ( $heap->{$jobID}->{'jmJobData'} )
        {
            my $jmJobData = Copilot::Util::stringToHash($heap->{$jobID}->{'jmJobData'});
            $jmJobData->{'wallTime'} = $heap->{$jobID}->{'wallTime'};
            $jobData->{'jmJobData'} = Copilot::Util::hashToString($jmJobData);
        }
        else
        {
            $jobData->{'jmJobData'} = Copilot::Util::hashToString({'wallTime' => $heap->{$jobID}->{'wallTime'}});
        }

        $kernel->yield ('componentJobDone', $jobData );
   }
   else {}
}

#
# Reports that the job has been done
sub componentJobDoneHandler
{
    my ( $kernel, $heap, $jobData) = @_[ KERNEL, HEAP, ARG0];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};

    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jobID = $heap->{'currentJobID'};

    my $toSend = $jobData;
    my $to =  $heap->{$jobID}->{'StorageManagerAddress'};

    $toSend->{'command'} = 'jobDone';

    my $done = {
                'to' => $to,
                'info'  => $toSend,
               };

    $kernel->yield ('componentLogMsg', "************************************************************");
    $kernel->yield ('componentLogMsg', "Reporting to jobmanager ($to) that the job (ID: $jobID) has been completed");
    $kernel->yield ('componentLogMsg', "************************************************************\n");
    $kernel->post ($container, $sendHandler, $done);

    $heap->{$jobID}->{'state'} = 'done';

    # We schedule job request again
    $self->{'COMPONENT_HAS_JOB'} = 0;
    $self->{'COMPONENT_WAITING_JOB'} = 0;
    $self->{'COMPONENT_HAS_OUTPUT_DIR'} = 0;
    $self->{'COMPONENT_WAITING_OUTPUT_DIR'} = 0;

    $kernel->yield ('componentLogMsg', "Scheduling new job request");
    $kernel->yield ('componentWantGetJob');
}

#
# Puts job output files back to the server
sub componentPutJobOutputFilesHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    my $jobID = $heap->{'currentJobID'};
    my $job = $heap->{$jobID}->{'job'};

    my $putMethod;
    my $methodParam;

    if ( defined ($job->{'outputChirpUrl'} ))
    {
        $putMethod = 'chirpPut';
        $methodParam = $job->{'outputChirpUrl'};
    }
    else
    {
        print "Method for getting file is unknown or not specified\n";
        $kernel->yield ('componentError');
        return;
    }

    # get all files in workdir and put into hash
    my $workdir = $heap->{$jobID}->{'workdir'};

    # archive the contents of job output directory
    $kernel->yield ('componentLogMsg', "Compressing job directory $workdir", 'debug');
    `tar --directory $workdir -cvzf $workdir/$jobID.tgz --exclude $jobID.tgz .`;


    $kernel->yield ('componentLogMsg', 'Starting uploading output for job (ID: '. $jobID . ')');
    $kernel->yield ($putMethod, $methodParam, "$workdir/$jobID.tgz", "$jobID/$jobID.tgz");

    $kernel->yield ('componentDispatchJob'); # this is to signal that file uploading is done
}

#
# Uploads the file to chirp server
sub chirpPutHandler
{
    my ($kernel, $chirpServer, $localFile, $remoteFile) = @_[ KERNEL, ARG0, ARG1, ARG2 ];

#    my $copyFileCmd = "parrot -a hostname cp $localFile /chirp/$chirpServer/$remoteFile";
    my $copyFileCmd = "chirp_put -a address $localFile  $chirpServer $remoteFile";
    my $returnCode = system ("$copyFileCmd && wait");

    $returnCode = $returnCode >> 8;

    if ($returnCode != 0)
    {
        $kernel->yield ('componentError', "Failed to upload output file ($copyFileCmd). Exit code $returnCode");
        return;
    }

    $kernel->yield('componentLogMsg', "Uploaded $localFile for the job.", 'info');
}

sub componentWantGetJobOutputDirHandler
{
    my ($kernel, $heap, $originalJobID) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};
    my $jobID = $heap->{'currentJobID'};

    $self->{'wantOutputDirTrial'} = 1 if not defined($self->{'wantJobTrial'});

    if ($self->{'COMPONENT_WAITING_OUTPUT_DIR'} != 0 or $self->{'COMPONENT_HAS_OUTPUT_DIR'} != 0 or (defined($originalJobID) and $heap->{$originalJobID}->{'state'} eq 'done') )
    {
        $kernel->yield('componentLogMsg', "Got reply for want_getJobOutputDir. Purging previously scheduled job output directory requests.", 'debug');
        return;
    }
    else
    {
        if (defined($originalJobID) and $originalJobID ne $jobID)
        {
            $kernel->yield('componentLogMsg', "Purging want_getJobOutputDir equest for job $originalJobID.", 'debug');
            return;
        }
        my $waitTime = 60 * $self->{'wantOutputDirTrial'};
        $kernel->yield('componentLogMsg', "Scheduling another want_getJobOutputDir request in $waitTime seconds for the job $jobID", 'debug');
        $self->{'wantOutputDirTrial'} *= 2;
        $kernel->delay('componentWantGetJobOutputDir', $waitTime, $jobID);
        $self->{'wantOutputDirTrial'} = 1 if $self->{'wantOutputDirTrial'} > 60; # Reset the counter after we reached 1 hour
    }

    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $to = $self->{'JOB_MANAGER_ADDRESS'};

    my $toSend = {};
    $toSend->{'command'} = 'want_getJobOutputDir';
    $toSend->{'jobID'} = $jobID;

    if ( $heap->{$jobID}->{'jmJobData'} )
    {
        $toSend->{'jmJobData'} = $heap->{$jobID}->{'jmJobData'};
    }

    my $hostname = `hostname -f`;
    chomp $hostname;
    $toSend->{'agentHost'} = $hostname;
    $toSend->{'agentIP'} = 'todo';

    my $outputDirRequest = {
                             'to' => $to,
                             'info' => $toSend,
                           };

    $kernel->yield ('componentLogMsg', "Asking $to for an address of the storage manager for job (ID: $jobID)");
    $heap->{'expectedCommand'} = 'have_getJobOutputDir';
    $kernel->post ($container, $sendHandler, $outputDirRequest);
}

#
# Requests the output directory for the job
sub componentGetJobOutputDirHandler
{
    my ($kernel, $heap, $from) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    $self->{'COMPONENT_WAITING_OUTPUT_DIR'} = 1;

    my $jobID = $heap->{'currentJobID'};

    #my $to = $heap->{$jobID}->{'JobManagerAddress'};
    #my $to = $self->{'JOB_MANAGER_ADDRESS'};
    my $to = $from;

    my $toSend = {};
    $toSend->{'command'} = 'getJobOutputDir';
    $toSend->{'jobID'} = $jobID;
    if ( $heap->{$jobID}->{'jmJobData'} )
    {
        $toSend->{'jmJobData'} = $heap->{$jobID}->{'jmJobData'};
    }

    my $hostname = `hostname -f`;
    chomp $hostname;
    $toSend->{'agentHost'} = $hostname; # Necessary to open access on the chirp server

    my $outputDirRequest = {
                                'to' => $to,
                                'info'=> $toSend,
                           };

    $kernel->yield ('componentLogMsg', "Asking jobmanager ($to) for an output directory for job (ID: $jobID)");
    $kernel->delay ('componentStopWaitingOutputDir', 10);
    $kernel->post ($container, $sendHandler, $outputDirRequest);
}

sub componentStopWaitingOutputDirHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP];
    my $self = $heap->{'self'};

    if ($self->{'COMPONENT_WAITING_OUTPUT_DIR'} == 1)
    {
        $self->{'COMPONENT_WAITING_OUTPUT_DIR'} = 0;
        $kernel->yield ('componentWantGetJobOutputDir');
    }
    else
    {
        $kernel->yield ('componentLogMsg', 'Purging previously scheduled getJobOutputDir request', 'debug');
    }
}

#
# Stores the output dir of the job and yields event for uploading job output (dispatchJob)
sub storeOutputDirHandler
{
    my ($kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0 ];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};
    my $logHandler = $self->{'LOG_HANDLER'};

    my $jobID = $input->{'jobID'};
    my $job = $heap->{$jobID}->{'job'};
    $heap->{$jobID}->{'StorageManagerAddress'} = $input->{'from'};

    if ( $input->{'jmJobData'} )
    {
        $heap->{$jobID}->{'jmJobData'} = $input->{'jmJobData'};
    }

    $job->{'outputChirpUrl'} = $input->{'outputChirpUrl'};
    $job->{'outputDir'} = $input->{'outputDir'};

    $kernel->post ($container, $logHandler, 'Stored job output directory data for job (ID: '. $jobID. ' )');
    $self->{'COMPONENT_HAS_OUTPUT_DIR'} = 1;
    $kernel->yield ('componentDispatchJob'); # this is to signal that output dir is ready
}
#
# Gets the input files of the job
sub componentGetJobInputFilesHandler
{

    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    my $self = $heap->{'self'};

    my $jobID = $heap->{'currentJobID'};
    my $job = $heap->{$jobID}->{'job'};

    $kernel->yield ('componentLogMsg', 'Starting fetching input files for job (ID: '. $jobID . ')');

    # Fetch the job input files
    $heap->{$jobID}->{'workdir'} = $self->{'AGENT_WORKDIR'}.'/'.$job->{'id'};

    my $getMethod;
    my $methodParam;
    my $jobInputDirRemote;
    my $jobInputDirLocal = $heap->{$jobID}->{'workdir'};

    if ( defined ($job->{'chirpUrl'} ))
    {
        $getMethod = 'chirpGet';
        $methodParam = $job->{'chirpUrl'};
        $jobInputDirRemote = $job->{'inputDir'};
    }
    else
    {
        print "Method for getting file is unknown or not specified\n";
        $kernel->yield ('componentError');
    }

    # create working directory of the job
    $kernel->yield ('createJobWorkDir', $jobInputDirLocal);

    # fetch input files
    my @files = split ('###', $job->{'inputFiles'});

    foreach my $file (@files)
    {
        $file eq '' and next;
        my $remoteFile = $jobInputDirRemote."/$file";
        my $localFile = $jobInputDirLocal."/$file";

        $kernel->yield ($getMethod, $methodParam, $remoteFile, $localFile );
    }

    $kernel->yield ('componentLogMsg', 'Fetching input files for job (ID: '. $jobID . ') is finished');
    $kernel->yield ('componentDispatchJob'); # this is to signal that file fetching is done
}

#
# Create working directory for the job
sub createJobWorkDirHandler
{
    my ( $kernel, $dir) = @_[ KERNEL, ARG0 ];

    $kernel->yield ('componentLogMsg', 'Creating working directory '. $dir. ' for the job.');

    my $returnCode = system ("mkdir -p $dir && wait");

    ($returnCode>>8) or return; #everything went well

    $kernel->yield ('componentError');
}

#
# Gets the file from chirp server
sub chirpGetHandler
{

    my ($kernel, $chirpServer, $remoteFile, $localFile) = @_[ KERNEL, ARG0, ARG1, ARG2 ];

    # my $copyFileCmd = "parrot -a hostname cp /chirp/$chirpServer/$remoteFile $localFile";
    my $copyFileCmd = "chirp_get -a address $chirpServer $remoteFile $localFile";

    my $returnCode = system ("$copyFileCmd && wait");

    $returnCode = $returnCode >> 8;

    $returnCode or return; # everything went well


    # otherwise
    $kernel->yield ('componentError', "Failed to download input file ($copyFileCmd). Exit code $returnCode");
}

#
# Creates job wrapper script
sub componentCreateJobWrapperHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP ];

    my $jobID = $heap->{'currentJobID'};

    $heap->{$jobID}->{'job'}->{'wrapper'} = $heap->{$jobID}->{'workdir'}."/_wrapper_.sh";
    my $job = $heap->{$jobID}->{'job'};

    my $wFile = $job->{'wrapper'};

    # create the file
    open (WF, "> $wFile");

    print WF "#!/bin/sh\n";

    #prepare packages
    my @pkg = split (/\s/, $job->{'packages'});

    foreach my $package (@pkg)
    {
        print WF "# Environment variables for $package\n";

        # package names have the following format: VO_NAME@PKG_NAME::VERSION (e.g. VO_ALICE@AliRoot::v4-16-Rev-01)
        # alienv expects PKG_NAME/VERSION so we need to convert

        # remove VO_NAME@
        $package =~ s/^(.*\@)//;

        # substitute :: with /
        $package =~ s/(::)/\//;

        # print package related env vars to the wrapper file
        my $vars = `alienv print $package`;
        print WF "$vars\n\n";

    }

    # prepare environement variables
    print WF "\n# Environment variables needed by the job\n";
    print WF $job->{'environment'}. "\n";

    # prepare command
    print WF "\n# Job command execution\n";
    print WF "cd ".$heap->{$jobID}->{'workdir'}."\n";
    print WF "chmod a+x ".  $heap->{$jobID}->{'job'}->{'command'}."\n";

    # execute the command
    print WF "/usr/bin/time -f \%U -o _walltime_ ./".$heap->{$jobID}->{'job'}->{'command'}." ". $heap->{$jobID}->{'job'}->{'arguments'}."\n";
    #print WF "exit $?";

    close WF;

    $kernel->yield ('componentLogMsg', 'Create wrapper script for job (ID: '. $jobID . ')');
    $kernel->yield ('componentDispatchJob'); # this is to signal that file fetching is done
}


#
# Executes the job command
sub componentExecuteJobCommandHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP ];

    my $jobID = $heap->{'currentJobID'};
    my $job = $heap->{$jobID}->{'job'};

    my $wrapper = $job->{'wrapper'};
    my $workDir = $heap->{$jobID}->{'workdir'};

    my $cmd = "cd $workDir && chmod a+x $wrapper && . $wrapper";

    $kernel->sig(CHLD => 'jobWheelFinished');

    # create stdout, stderr and resources files in working directory of the job
    # beacuse AliEn expects them to be there
    my $wd =  $heap->{$jobID}->{'workdir'};
    system ("touch $wd/stdout $wd/stderr $wd/resources");


    $heap->{$jobID}->{'wheel'} = POE::Wheel::Run->new(
                                                        Program => $cmd,
                                                        StdoutEvent => 'jobWheelStdout',
                                                        StderrEvent => 'jobWheelStderr',
                                                        StdioFilter  => POE::Filter::Line->new(),
                                                        StderrFilter => POE::Filter::Line->new(),
                                                        ErrorEvent => 'jobWheelError',
                                                    );
    my $childPID = $heap->{$jobID}->{'wheel'}->PID;
    $heap->{$jobID}->{'childPID'} = $childPID;

    $kernel->yield ('componentLogMsg', "Starting child process (PID: $childPID) to execute the command for job (Job ID: $jobID)");
}

sub jobWheelErrorHandler
{
    my ( $hash, $operation, $code, $msg, $handle ) = @_[ HEAP, ARG0, ARG1, ARG2, ARG4 ];

    if ( ($operation eq 'read') and ($code == 0) and ($handle eq 'STDERR' or $handle  eq 'STDOUT') and ($msg eq'') )
    { return; } # this situation is normal
    else
    {
        print "\n\nFailed to $operation: $msg (Error code: $code). Handle: $handle\n\n";
        #yield->error();
    }
}

#
# function for handlig STDERR of the command. Gets the string and puts it to STDERR file in job work dir
sub jobWheelStderrHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];
    my $jobID = $heap->{'currentJobID'};
    my $wd = $heap->{$jobID}->{'workdir'};

    my $fh = $heap->{$jobID}->{'STDERR_HANDLE'};
    unless (defined($fh))
    {
        open $fh, "> $wd/stderr";
        $heap->{$jobID}->{'STDERR_HANDLE'} = $fh;
    }

    print $fh "$txt\n";
}

#
# function for handling STDOUT of the command. Gets the string and puts it to STDOUT file in job work dir
sub jobWheelStdoutHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];

    my $jobID = $heap->{'currentJobID'};
    my $wd = $heap->{$jobID}->{'workdir'};

    my $fh = $heap->{$jobID}->{'STDOUT_HANDLE'};


    unless ( defined ($fh))
    {
        open $fh, "> $wd/stdout";
        $heap->{$jobID}->{'STDOUT_HANDLE'} = $fh;
    }

    print $fh "$txt\n";
}

#
# Is called when job fishes
sub jobWheelFinishedHandler
{
    my ($heap, $kernel, $childPID, $exitCode) = @_[HEAP, KERNEL, ARG1, ARG2 ];

    my $jobID = $heap->{'currentJobID'};

    return if ($childPID != $heap->{$jobID}->{'childPID'});
    
    # Child process (PID: $childPid) for job (Job ID: $jobID) finished with: $retVal
    $heap->{$jobID}->{'exitCode'}  = $exitCode;

    # close STDOUT and STDERR handles;
    my $fh = $heap->{$jobID}->{'STDOUT_HANDLE'};
    $fh and close $fh;

    $fh = $heap->{$jobID}->{'STDERR_HANDLE'};
    $fh and close $fh;

    my $wallfile = $heap->{$jobID}->{'workdir'} . "/_walltime_";
    my $walltime = `tail -n 1 $wallfile`;
    chomp $walltime;
    `rm $wallfile`;
    $heap->{$jobID}->{'wallTime'} = $walltime;

    $kernel->yield('componentLogMsg', "Execution of child process (PID: $childPID) finished with \'$exitCode\' in $walltime seconds");

    # destroy the wheel
    my $j =  $heap->{$jobID};
    delete $j->{'wheel'};

    $kernel->yield ('componentDispatchJob'); # this is to signal that command execution is done
}

#
# Validates the job
sub componentValidateJobHandler
{
    my ( $kernel, $heap) = @_[ KERNEL, HEAP ];

    my $jobID = $heap->{'currentJobID'};
    my $job = $heap->{$jobID}->{'job'};

    if (! $heap->{$jobID}->{'job'}->{'validationScript'} )
    {

        $kernel->yield ('componentLogMsg', "The job (Job ID: $jobID) does not require validation");
        $kernel->yield ('componentDispatchJob'); # this is to signal that the job validation is done (not needed)
        return;
    }

    my $vs = $heap->{$jobID}->{'job'}->{'validationScript'};

    my $cmd = "cd ".$heap->{$jobID}->{'workdir'}." && chmod a+x $vs && ./$vs";

    $kernel->sig(CHLD => 'validateWheelFinished');

    # create stdout, stderr and resources files in working directory of the job
    # beacuse AliEn expects them to be there
    my $wd =  $heap->{$jobID}->{'workdir'};
    system ("touch $wd/validate_stdout $wd/validate_stderr ");


    $heap->{$jobID}->{'validateWheel'} = POE::Wheel::Run->new(
                                                              Program => $cmd,
                                                              StdoutEvent => 'validateWheelStdout',
                                                              StderrEvent => 'validateWheelStderr',
                                                              StdioFilter  => POE::Filter::Line->new(),
                                                              StderrFilter => POE::Filter::Line->new(),
                                                              ErrorEvent => 'validateWheelError',
                                                            );
    my $childPID = $heap->{$jobID}->{'validateWheel'}->PID;
    $heap->{$jobID}->{'validatePID'} = $childPID;

    $kernel->yield ('componentLogMsg', "Starting child process (PID: $childPID) to validate the job (Job ID: $jobID)");


}

#
# Is called when error occurs during the validation command execution
sub validateWheelErrorHandler
{
    my ( $hash, $operation, $code, $msg, $handle ) = @_[ HEAP, ARG0, ARG1, ARG2, ARG4 ];

    if ( ($operation eq 'read') and ($code == 0) and ($handle eq 'STDERR' or $handle  eq 'STDOUT') and ($msg eq'') )
    { return; } # this situation is normal
    else
    {
        print "\n\nFailed to $operation: $msg (Error code: $code). Handle: $handle\n\n";
        #yield->error();
    }

}

#
# Handles STDERR of validation script
sub validateWheelStderrHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];
    my $jobID = $heap->{'currentJobID'};
    my $wd = $heap->{$jobID}->{'workdir'};

    my $fh = $heap->{$jobID}->{'VALIDATE_STDERR_HANDLE'};
    unless (defined($fh))
    {
        open $fh, "> $wd/validate_stderr";
        $heap->{$jobID}->{'VALIDATE_STDERR_HANDLE'} = $fh;
    }

    print $fh "$txt\n";
}

#
# Handles STDOUT of validation script
sub validateWheelStdoutHandler
{
    my ($heap, $txt) = @_[HEAP, ARG0];

    my $jobID = $heap->{'currentJobID'};
    my $wd = $heap->{$jobID}->{'workdir'};

    my $fh = $heap->{$jobID}->{'VALIDATE_STDOUT_HANDLE'};


    unless ( defined ($fh))
    {
        open $fh, "> $wd/validate_stdout";
        $heap->{$jobID}->{'VALIDATE_STDOUT_HANDLE'} = $fh;
    }

    print $fh "$txt\n";
}

#
# Is called when validation script finishes
sub validateWheelFinishedHandler
{
    my ($heap, $kernel, $childPID, $exitCode) = @_[HEAP, KERNEL, ARG1, ARG2 ];

    my $jobID = $heap->{'currentJobID'};

    # Child process (PID: $childPid) for job (Job ID: $jobID) finished with: $retVal
    $heap->{$jobID}->{'validateExitCode'}  = $exitCode;

    # close STDOUT and STDERR handles;
    my $fh = $heap->{$jobID}->{'VALIDATE_STDOUT_HANDLE'};
    $fh and close $fh;

    $fh = $heap->{$jobID}->{'VALIDATE_STDERR_HANDLE'};
    $fh and close $fh;

    $kernel->yield('componentLogMsg', "Execution of child process (PID: $childPID) finished with \'$exitCode\'");

    # destroy the wheel
    my $j =  $heap->{$jobID};
    delete $j->{'validateWheel'};

    $kernel->yield ('componentDispatchJob'); # this is to signal that the job validation is done

}


#
# Method for reporting errors and stopping the work of the agent
sub componentErrorHandler
{
    my $errorMsg = $_[ARG0];
    print "In componentErrorHandler\n";
    die $errorMsg;
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
    my $jobID = $data->{'jobID'};

    my $forwardRequest = {
                            'to'   => $to,
                            'info' => $data,
                         };

    $kernel->yield ('componentLogMsg', 'Bouncing '. $command .' to '. $to . 'for job (ID: '. $jobID.' )');

    $kernel->post ($container, $sendHandler, $forwardRequest);
}

"M";
