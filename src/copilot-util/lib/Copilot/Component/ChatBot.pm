package Copilot::Component::ChatBot;

=head1 NAME Copilot::Component::ChatBot

=head1 DESCRIPTION

This class implements the ChatBot for the Copilot system. The component provides a command line interface for sending and receiving 
XMPP messages. It is inteded to be used for testing and debugging of other components. The ChatBot inherits from Copilot::Component (for general 
information  about the Components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within 
one of the component containers (e.g. Copilot::Container::XMPP). 

    Exmaple:

    my $agent = new Copilot::Container::XMPP (
                                    {
                                      Component => 'ChatBot',
                                      LoggerConfig => $loggerConfig,
                                      JabberID => $jabberID,
                                      JabberPassword => $jabberPassword,
                                      JabberDomain => $jabberDomain,
                                      JabberServer => $jabberServer,

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
                                                componentGetConsoleCommand => \&componentGetConsoleCommandHandler,

											    # Commands 
                                                getJob => \&getJobHandler,	

 #												componentHello => \&componentHelloHandler,
 #                                               componentGetJob => \&componentGetJobHandler,
 #                                               componentStartJob => \&componentStartJobHandler,
 #                                               componentDispatchJob => \&componentDispatchJobHandler, 
 #                                               componentGetJobInputFiles => \&componentGetJobInputFilesHandler,
 #                                                  chirpGet => \&chirpGetHandler,
 #                                                  createJobWorkDir => \&createJobWorkDirHandler,
 #                                               componentCreateJobWrapper => \&componentCreateJobWrapperHandler,
 #                                               componentExecuteJobCommand => \&componentExecuteJobCommandHandler,
 #                                                   jobWheelFinished => \&jobWheelFinishedHandler,
 #                                                   jobWheelStdout => \&jobWheelStdoutHandler,
 #                                                   jobWheelStderr => \&jobWheelStderrHandler,
 #                                                   jobWheelError => \&jobWheelErrorHandler,
 #                                               componentValidateJob => \&componentValidateJobHandler,
 #                                                   validateWheelFinished => \&validateWheelFinishedHandler,
 #                                                   validateWheelStdout => \&validateWheelStdoutHandler,
 #                                                   validateWheelStderr => \&validateWheelStderrHandler,
 #                                                   validateWheelError => \&validateWheelErrorHandler,
 #                                               componentGetJobOutputDir => \&componentGetJobOutputDirHandler,
 #                                                   storeOutputDir => \&storeOutputDirHandler,
 #                                               componentPutJobOutputFiles => \&componentPutJobOutputFilesHandler,
 #                                                   chirpPut => \&chirpPutHandler,
 #                                              componentJobDone => \&componentJobDoneHandler,
 #                                              componentError => \&componentErrorHandler,

                                                componentLogMsg => \&componentLogMsgHandler,
#                                               componentRedirect => \&componentRedirectHandler,
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

    $self->{'LOG_HANDLER'} = ($options->{'CONTAINER_LOG_HANDLER'} || 'logger');
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
	
	$self->{'COMMANDS'} = { 'getJob' => 1,};	

    #$_[SESSION]->option (trace => 1);
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
   # $kernel->yield ('componentGetJob'); 
 	
   $kernel->yield ('componentGetConsoleCommand');

   # Write to log file
   # $kernel->yield ('componentLogMsg', "Component was waken up. Asking job manager for a job", 'info'); 

   $self->{'COMPONENT_HAS_JOB'} = 0;	
}

#
# Handles input from server 
sub componentInputHandler
{
    my ( $kernel, $input) = @_[ KERNEL, ARG0, ARG1 ];
    $kernel->yield ('componentProcessInput', $input);
    $kernel->yield ('componentLogMsg', Dumper $input)
}

#
# Does input processing and dispatches the command (e.g. starts job) 
sub componentProcessInputHandler
{
    my ( $kernel, $heap, $input) = @_[ KERNEL, HEAP, ARG0];
	my $self = $heap->{'self'};	
   	 
    if ($input->{'command'} eq 'redirect')
    {
        # call redirector 
        $kernel->yield ('componentRedirect', $input); 
        # log
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
    }
    elsif ($input->{'command'} eq 'runJob')
    {   
	    $self->{'COMPONENT_HAS_JOB'} = 1;
        # prepare job data on the heap and pass control to the dispatcher function
        $kernel->yield('componentStartJob', $input);
        # log 
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
    }
    elsif ($input->{'command'} eq 'storeJobOutputDir')
    {
        # Store output dir and upload the files
        $kernel->yield('storeOutputDir', $input);
        # log 
        $kernel->yield('componentLogMsg', 'Got '. $input->{'command'});
    }
    elsif ($input->{'command'} eq 'error')
    {
        $kernel->yield('componentLogMsg', 'Got error:'. Dumper $input);
        $kernel->delay('componentError', 2); 
    }
}

#
#
sub componentGetConsoleCommandHandler
{
    my ($kernel, $heap) = @_ [ KERNEL, HEAP ];
    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    
    print "Waiting for input: ";        
    my $i = <STDIN>;
	
	my ($to, $command, @options) = split (/\s+/, $i);

    print "Got T: $to C: $command O: @options\n\n";    
	$kernel->delay ('componentGetConsoleCommand', 1);

	if (defined($self->{'COMMANDS'}->{$command}))
    {
        $kernel->yield($command, $to, join (' ' , @options));
        return;
    }
    else
    {
        $kernel->yield('componentLogMsg', "Command $command not found");
    }

}

#
# Asks for a job
sub getJobHandler
{
    my ( $kernel, $heap, $to ) = @_[ KERNEL, HEAP, ARG0];
	my @options = split (' ', $_[ ARG1 ]);

    my $self = $heap->{'self'};
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jdl = new Copilot::Classad::Host();

    my $hostname = `hostname -f`;
    chomp $hostname;     
   
    my $jobRequest = {  
                        'to'   => $to,
                        'info' =>
                                  {
                                    'command'   => 'getJob',
                                    'jdl'       => $jdl->asJDL(),
                                    'agentHost' => $hostname, # needed to open access on chir server
                                  },
                     };  
                    
    $kernel->yield ('componentLogMsg', 'Asking '. $to.' for a job');
    $kernel->post ($container, $sendHandler, $jobRequest);
}
#
# 
sub componentHelloHandler
{
	my ( $kernel, $heap) = @_[ KERNEL, HEAP];

    my $self = $heap->{'self'};

    my $container = $self->{'CONTAINER_ALIAS'};

    my $sendHandler = $self->{'SEND_HANDLER'};

    my $hostname = `hostname -f`;
    chomp $hostname;     
   
    my $jobRequest = {  
                        'to'   => $self->{'JOB_MANAGER_ADDRESS'},
                        'info' =>
                                  {
                                    'command'   => 'Hello '.$ENV{'CERNVM_UUID'},
                                    'agentHost' => $hostname, # needed to open access on chir server
                                  },
                     };  
                    
    $kernel->yield ('componentLogMsg', 'Asking '. $self->{'JOB_MANAGER_ADDRESS'}.' for a job');
    $kernel->post ($container, $sendHandler, $jobRequest);
    $kernel->delay ('componentGetJob', 300); 
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
        $kernel->yield ('componentGetJobOutputDir');              
    }
    elsif ($prevState eq 'getOutputDir') 
    {
        # done getting the driectory now we have to upload files
        $heap->{$jobID}->{'state'} = 'putOutput';
        $kernel->yield ('componentPutJobOutputFiles');                     
    }
    elsif ($prevState eq 'putOutput') 
    {
        $heap->{$jobID}->{'state'} = 'done';

        my $jobData = { 'state'    => $heap->{$jobID}->{'state'},
                        'exitCode' => $heap->{$jobID}->{'exitCode'},
                        'jobID'    => $jobID,
                      };

        if ( $heap->{$jobID}->{'job'}->{'validationScript'} )
        {
            $jobData->{'validateExitCode'} = $heap->{$jobID}->{'validateExitCode'};
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
    my $to =  $heap->{$jobID}->{'JobManagerAddress'};

    $toSend->{'command'} = 'jobDone';
    
    my $done = {
                'to' => $to,
                'info'  => $toSend,
               };    

    $kernel->yield ('componentLogMsg', "Reporting to jobmanager ($to) that the job (ID: $jobID) has been completed");
    $kernel->post ($container, $sendHandler, $done);
    
}

#
# Puts job output files back to the server
sub componentPutJobOutputFilesHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    my $jobID = $heap->{'currentJobID'};
    my $job = $heap->{$jobID}->{'job'};
 
    $kernel->yield ('componentLogMsg', 'Starting uploading output files for job (ID: '. $jobID . ')');

    # get the list of input files
    my @inputFiles = split ('###', $job->{'inputFiles'});

    # get all files in workdir and put into hash
    my $workdir = $heap->{$jobID}->{'workdir'};
    my %outFiles = map { $_, $workdir.'/'.$_ } split (/\s/, `ls -a $workdir`); 

    # remove input files from the hash, and what remains is the list of output files
    foreach my $inputFile (@inputFiles)
    {      
        delete $outFiles{$inputFile};
    }

    delete $outFiles{'.'};
    delete $outFiles{'..'};
   
    my $putMethod;
    my $methodParam;
    my $jobOutputDirRemote;
    my $jobOutputDirLocal = $heap->{$jobID}->{'workdir'};

    if ( defined ($job->{'outputChirpUrl'} ))
    {
        $putMethod = 'chirpPut';
        $methodParam = $job->{'outputChirpUrl'};
        $jobOutputDirRemote = $job->{'outputDir'};
    }
    else
    {
        print "Method for getting file is unknown or not specified\n";
        $kernel->yield ('componentError');
    }

    foreach my $file (keys %outFiles)
    {
        my $remoteFile = $jobOutputDirRemote."/$file";
        my $localFile = $jobOutputDirLocal."/$file";

        $kernel->yield ($putMethod, $methodParam, $remoteFile, $localFile );
    }

    $kernel->yield ('componentLogMsg', 'Uploading output files for job (ID: '. $jobID . ') is finished');
    $kernel->yield ('componentDispatchJob'); # this is to signal that file uploading is done
}

#
# Uploads the file to chirp server
sub chirpPutHandler
{
    my ($kernel, $chirpServer, $remoteFile, $localFile) = @_[ KERNEL, ARG0, ARG1, ARG2 ];

#    my $copyFileCmd = "parrot -a hostname cp $localFile /chirp/$chirpServer/$remoteFile";
    my $copyFileCmd = "chirp_put $localFile  $chirpServer $remoteFile";
    my $returnCode = system ("$copyFileCmd && wait");  

    $returnCode = $returnCode >> 8;

    $returnCode or return; # everything went well
    
    # otherwise    
    $kernel->yield ('componentError', "Failed to upload output file ($copyFileCmd). Exit code $returnCode");
}

#
# Requests the output directory for the job 
sub componentGetJobOutputDirHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];

    my $self = $heap->{'self'};
    
    my $container = $self->{'CONTAINER_ALIAS'};
    my $sendHandler = $self->{'SEND_HANDLER'};

    my $jobID = $heap->{'currentJobID'};
    
    my $to = $heap->{$jobID}->{'JobManagerAddress'};
    
    my $toSend = {};
    $toSend->{'command'} = 'getJobOutputDir';
    $toSend->{'jobID'} = $jobID;

    my $hostname = `hostname -f`;
    chomp $hostname;    
    $toSend->{'agentHost'} = $hostname; # Necessary to open access on the chirp server
    
    my $outputDirRequest = {
                                'to' => $to,
                                'info'=> $toSend,
                           };
    
    $kernel->yield ('componentLogMsg', "Asking jobmanager ($to) for an output directory for job (ID: $jobID)");
    $kernel->post ($container, $sendHandler, $outputDirRequest);
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

    $job->{'outputChirpUrl'} = $input->{'outputChirpUrl'};
    $job->{'outputDir'} = $input->{'outputDir'};
    
    $kernel->post ($container, $logHandler, 'Stored job output directory data for job (ID: '. $jobID. ' )');       
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

 #   my $copyFileCmd = "parrot -a hostname cp /chirp/$chirpServer/$remoteFile $localFile";
    my $copyFileCmd = "chirp_get  $chirpServer $remoteFile $localFile";
     
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
    print WF "./".$heap->{$jobID}->{'job'}->{'command'}." ". $heap->{$jobID}->{'job'}->{'arguments'}."\n";    

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
# function for handlig STDOUT of the command. Gets the string and puts it to STDOUT file in job work dir
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

    # Child process (PID: $childPid) for job (Job ID: $jobID) finished with: $retVal 
    $heap->{$jobID}->{'exitCode'}  = $exitCode; 

    # close STDOUT and STDERR handles;
    my $fh = $heap->{$jobID}->{'STDOUT_HANDLE'};
    $fh and close $fh;

    $fh = $heap->{$jobID}->{'STDERR_HANDLE'};
    $fh and close $fh;

    $kernel->yield('componentLogMsg', "Execution of child process (PID: $childPID) finished with \'$exitCode\'"); 

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
    exit -1;
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
