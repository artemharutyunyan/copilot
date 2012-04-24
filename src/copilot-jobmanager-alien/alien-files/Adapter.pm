package AliEn::Service::JobAgent::Adapter;  

=head1 NAME AliEn::Service::JobAgent::Adapter

=head1 DESCRIPTION 

This class serves as an interface between x system and AliEn. It gets the job JDL from AliEn task queue, 
converts the job information from JDL into the format of x system agents. The class also allows to register 
the output of the job in the AliEn file catalogue. 
Inherits from AliEn::Service::JobAgent, but unlike the AliEn::Service::JobAgent it does not create listening sockets. 

=head1 METHODS

=over 

=item new($options)

Constructor for AliEn::Service::JobAgent::Adapter class. Takes as an input hash reference with options. 
The following options can be specified:

    jdl => the host jdl which will be sent to AliEn job broker (mandatory option)
    chirp_host => address of the chirp server (optional, default `hostname -f`)
    chirp_port => port on which chirp server is listening (optional, default 9094)

=cut

use strict;
use Data::Dumper;

use vars qw (@ISA);

use AliEn::Service::JobAgent;
use Copilot::GUID;

@ISA = qw (AliEn::Service::JobAgent);# AliEn::Service);

$SIG{INT} = sub { exit;};


=item finalizeJob()

Changes the state of the job according to return code of the job command execution. Registers the output files 
of the job in the file catalogue

=cut 

sub finalizeJob
{
    my $self = shift;
    my $exitCode  = shift;

    # restore job agent realted environment variables
    $self->restoreEnvironment();

    # redirect the logs so all print goes to the file
    # my $logFile= "$self->{CONFIG}->{LOG_DIR}/$self->{SERVICE}.wakesup.log";
    $self->{LOGGER}->redirect($self->{'LOGFILE'});

    $self->changeStatus($self->{STATUS}, "SAVING",$exitCode);	
    $self->info("Command executed with $exitCode.");

    $self->{STATUS}="SAVED";
 
    chdir $self->{'WORKDIR'};
    $self->putFiles() or $self->{STATUS}="ERROR_SV";
    $self->registerLogs();

    my $jdl;
    $self->{JDL_CHANGED} and $jdl=$self->{CA}->asJDL();
  
    my $success=$self->changeStatus("%",$self->{STATUS}, $jdl);


    $self->putJobLog("state", "The job finished on the worker node with status $self->{STATUS}");
    $self->{JOBLOADED}=0;
    $self->{SOAP}->CallSOAP("CLUSTERMONITOR", "jobExits", $ENV{ALIEN_PROC_ID});

    delete $ENV{ALIEN_JOB_TOKEN};
    delete $ENV{ALIEN_PROC_ID};

    # remove the workdir here 
    chdir;  
    #system("rm", "-rf", $self->{WORKDIR});

    # restore the logging 
    $self->{LOGGER}->redirect('');

    # preserve and clean job agent related environment variables
    $self->preserveEnvironment();

    return 1;
}


=item getJob()

Connects to AliEn job broker, and requests a job using the jdl provided in the constructor. If broker matches 
the host JDL with the job JDL from AliEn task queue returns a hash with the job description. Otherwise returns 
nothing. Contains code snippets from AliEn::Service::Agent's startListening(),  forkCheckProcess() and checkWakesUp()

=cut

sub getJob
{
    my $self = shift;
 
    # restore job agent realted environment variables
    $self->restoreEnvironment();

    eval 
    {
        require AliEn::Server::SOAP::Transport::HTTP;
        require AliEn::Server::SOAP::Transport::HTTPS;
    };
    
    if ($@)
    {
        $self->info("Error requiring the transport methods!! $@");
        return;
    }
    
    $self->setAlive();

    # callback if requested
    $self->dumpEnvironment();
    $self->doCallback(1);

#  my $logFile= "$self->{CONFIG}->{LOG_DIR}/$self->{SERVICE}.wakesup.log";
#  $self->info("************Redirecting the log of the checkWakesUp to $logFile");
#  $self->{LOGGER}->redirect($logFile);

    if (! $self->{JOBLOADED}) 
    {
        $self->sendJAStatus('REQUESTING_JOB');
        $self->info("Asking for a new job");
  
        if (! $self->requestJob())
        {
            $self->sendJAStatus('DONE');
            $self->info("There are no jobs to execute");

            #Tell the CM that we are done"
            $self->{SOAP}->CallSOAP("CLUSTERMONITOR", "agentExits", $ENV{ALIEN_JOBAGENT_ID});

            # restore logs
            $self->{LOGGER}->redirect('');

            return;
      # killeverything connected
#      $self->info("We have to  kill $self->{SERVICEPID} or ".getppid());
#      system("ps -ef |grep JOB");
#      unlink $self->{WORKDIRFILE};
#      system ("rm", "-rf", $self->{WORKDIRFILE});
#      $self->stopService(getppid());
#      kill (9, getppid());
#      exit(0);
        }
    }

    if ($self->{STARTTIME} eq '0')
    {
        my $date =localtime;
        $date =~ s/^\S+\s(.*):[^:]*$/$1/;
        $self->{STARTTIME} = $date;
    }

    #restore logs 
    $self->{LOGGER}->redirect('');

    # environment variables will be preserved in prepareJobData()
    return $self->prepareJobData(); 
}

=item createChirpACL($aclString)

Creates chirp acl file in the job's working directory and puts $aclString to the file

=cut
sub createChirpACL
{
    my $self = shift;
    my $control = shift; 
   
    my $wd = $self->{'WORKDIR'};
    
    `mkdir -p $wd`;
    
    open ACL, "> $wd/.__acl" or return; 
    print ACL "$control\n";
    close ACL;

    return 1;
}


#
# Internal functions. 
#

#
# Deletes all the environment variables which contain ALIEN_ in their name. This is done, because 
# many instances of AliEn::Service::JobAgent::Adapter must be within the same process and they should
# not interfere
sub preserveEnvironment
{
    my $self = shift;
    $self->{'ENV'} = {};

	my $keysToDelete = {};
	my $keysToKeep = {'ALIEN_PROMPT' => 1,
			  'ALIEN_VERSION' => 1,
			  'ALIEN_NAME_SERVER' => 1,
			  'ALIEN_ROOT' => 1,
			  'ALIEN_PERL' => 1,
			  'ALIEN_CA' => 1,
			  'ALIEN_CM_AS_LDAP_PROXY' => 1,
			  'ALIEN_HOSTNAME' => 1,
			  'ALIEN_USER' => 1,
			  'ALIEN_LD_LIBRARY_PATH' => 1,
			  'ALIEN_PATH' => 1,
			  'ALIEN_HOME' => 1,
			  'ALIEN_DOMAIN' => 1,	
			  'ALIEN_JOBAGENT_ID' => 1,
			  'ALIEN_PROCESSNAME' => 1,
			  'ALIEN_ENV' => 1,
			  'ALIEN_ORGANISATION' => 1,
			};

    foreach my $key (keys %ENV)
    {
       ($key =~ /^ALIEN_/) or next; # we skip if the name of the environment variable doesn't start with 'ALIEN_'

       $self->{'ENV'}->{$key} = $ENV{$key};
       next if defined($keysToKeep->{$key});
	   delete $ENV{$key};			
    }

    return $self->{'ENV'};
}

#
# Restores the environment variables which were preserved before
sub restoreEnvironment
{
    my $self = shift;

    foreach my $key (keys %{$self->{'ENV'}})
    {
        $ENV{$key} = $self->{'ENV'}->{$key};
    }

}

#
# is called from AliEn::Service->new()
sub initialize 
{
    my $self = shift;
    my $options = (shift or {});
    my $logFile= "$self->{CONFIG}->{LOG_DIR}/$self->{SERVICE}.wakesup.log";
    $self->info("Redirecting the output of JobAgent to $logFile");
    $self->{LOGGER}->redirect($logFile);
   
    $self->SUPER::initialize($options, @_);


    # delete $self->{PACKMAN}, beacause it creates problems during deserialization and is not used anyway
    delete ($self->{'PACKMAN'});

    
    ($self->{WN_JDL} = $options->{jdl}) or die "JDL is not provided. Dying...";
    $options->{workdir} and ($self->{WORKDIR} = $options->{workdir});

    $self->{CHIRP_HOST} = $options->{chirp_host} || `hostname -f`;
    $self->{CHIRP_PORT} = $options->{chirp_port} || '9094';

    chomp $self->{CHIRP_HOST};

    # preserve and clean job agent related environment variables
    $self->preserveEnvironment();

    return $self;
}

#
# Restores the state of the object (deserialization)
sub restoreAdapter
{
    my $self = shift;
    my $prevState = shift;
    my $workdir = shift;

    $self->{'CA'} = new Classad::Classad ($prevState->{'CA'});
    $self->{'ENV'} = $prevState->{'ENV'};
   
    $self->{'LOGFILE'}="$self->{CONFIG}->{TMP_DIR}/proc.".$self->{'ENV'}->{'ALIEN_PROC_ID'}.".out";

    # Restore the content of the logfile
    open FH, "> $self->{'LOGFILE'}";
    print FH $prevState->{'JA_LOG_CONTENT'};
    close FH;

    # ... and redirect the logger
    $self->info("Let's redirect the output to $self->{LOGFILE}");
    $self->{'LOGGER'}->redirect ($self->{'LOGFILE'});
    
    $self->{'VOs'} = $prevState->{'VOs'};
    $self->{'STATUS'} = $prevState->{'STATUS'};

    $self->{'WORKDIR_RELATIVE_PATH'} = $prevState->{'WORKDIR_RELATIVE_PATH'};
    $self->{'WORKDIR'} = $workdir.$self->{'WORKDIR_RELATIVE_PATH'};

    foreach my $data (split (/\s+/, $self->{VOs}))
    {
        my ($org, $cm, $id, $token)=split ("#", $data); 
        $self->info("Connecting to services for $org");
        $self->{SOAP}->{"CLUSTERMONITOR_$org"}=SOAP::Lite
            ->uri("AliEn/Service/ClusterMonitor")
            ->proxy("http://$cm");

        $ENV{ALIEN_CM_AS_LDAP_PROXY}=$cm;
        $self->{CONFIG}=$self->{CONFIG}->Reload({"organisation", $org}); 

        $self->{SOAP}->{"Manager_Job_$org"}=SOAP::Lite
            ->uri("AliEn/Service/Manager/Job")
            ->proxy("http://$self->{CONFIG}->{JOB_MANAGER_ADDRESS}");
    }

    $self->{'LOGGER'}->redirect ('');
    return $self;       
}

#
# Stores the state of the object (serialization)
sub storeAdapter
{
    my $self = shift;

    # open LOG, "< $self->{'LOGFILE'}";
     
    my $stored = { 
                    'WORKDIR' => $self->{'WORKDIR'},
                    'CA' => $self->{'CA'}->asJDL(),
                    'ENV' => $self->{'ENV'},
                    'LOGFILE' => $self->{'LOGFILE'},
                    'VOs' => $self->{'VOs'},
                    'STATUS' => $self->{'STATUS'},
                    'WORKDIR_RELATIVE_PATH' => $self->{'WORKDIR_RELATIVE_PATH'},
                };

    return $stored;                
}


#
# Puts the job data into the hash
sub prepareJobData
{
    my $self = shift;

    my $job = {};
    $job->{'command'} = "command";
    $job->{'inputDir'} = "$self->{'WORKDIR_RELATIVE_PATH'}";
    $job->{'outputDir'} = "$self->{'WORKDIR_RELATIVE_PATH'}";

    # prepare input filenames  
    my $input = `ls $self->{'WORKDIR'}`;
    $input =~ s/\n/\#\#\#/g;
    $input =~ s/\#\#\#$//;
    $job->{'inputFiles'} = $input; 

    # prepare chirp server url 
    $job->{'chirpUrl'} = $self->{CHIRP_HOST}.':'.$self->{CHIRP_PORT};

    $job->{'id'} = $self->{'QUEUEID'};

    $job->{'packages'} = $ENV{'ALIEN_PACKAGES'};

    # preserve and clean job agent related environment variables
    #preserveEnvironment();
    my $jobAgentEnv = $self->preserveEnvironment();

    # prepare the string which contains environment variables which must be set on agent machine 
    my $envStr = '';

    foreach my $key (keys %$jobAgentEnv)
    {
        $envStr .= " $key='$jobAgentEnv->{$key}'";
    }

    $envStr and ($job->{'environment'} = $envStr);

    # prepare the arguments of the job to be executed
    $job->{'arguments'} = $self->{'ARG'};

    return $job; 
}


##
## Reuqetsts a job, and if there is a match gets the JDL, creates the workdir, etc. 
sub requestJob 
{
  my $self=shift;

  $self->{REGISTER_LOGS_DONE}=0;
  $self->{FORKCHECKPROCESS} = 0;
  $self->{CPU_CONSUMED}={VALUE=>0, TIME=>time};

  $self->GetJDL() or return;
  $self->info("Got the jdl");
#  $self->{LOGFILE}=AliEn::TMPFile->new({filename=>"proc.$ENV{ALIEN_PROC_ID}.out"});
  $self->{LOGFILE}="$self->{CONFIG}->{TMP_DIR}/proc.$ENV{ALIEN_PROC_ID}.out";
  if ($self->{LOGFILE})
  {
    $self->info("Let's redirect the output to $self->{LOGFILE}");
    $self->{LOGGER}->redirect($self->{LOGFILE});
  } 
  else
  {
    $self->info("We couldn't redirect the output...");
  }
  $self->checkJobJDL() or $self->sendJAStatus('ERROR_JDL') and return;

  $self->info("Contacting VO: $self->{VOs}");

  $self->CreateDirs or $self->sendJAStatus('ERROR_DIRS') and return;

  #let's put the workdir in the file
  open (FILE, ">$self->{WORKDIRFILE}") or print "Error opening the file $self->{WORKDIRFILE}\n" and return;
  print FILE "WORKDIR=$self->{WORKDIR}\n";
  close FILE;

  # Get job input files, command etc.
  # Before sending to the agent
  $self->getJobInputFiles() or return; 
 
  $self->sendJAStatus('JOB_STARTED');
  return 1;
}

 

##
## Called from requestJob to fetch input data 
## Partial copy of AliEn::Service::JobAgent->executeCommand, which is called from AliEn::Service::JobAgent->startMonitor()
sub getJobInputFiles
{
    my $self = shift;
    my $this = shift;
 
    $self->changeStatus("%",  "STARTED", 0,$self->{HOST}, $self->{PROCESSPORT} );
  
    $ENV{ALIEN_PROC_ID} = $self->{QUEUEID};
    my $catalog=$self->getCatalogue() or return;

    $self->debug(1, "Getting input files and command");
    if ( !( $self->getFiles($catalog) ) ) 
    {
        print STDERR "Error getting the files\n";
        $catalog->close();
        $self->registerLogs(0);

        $self->changeStatus("%",  "ERROR_IB");
        return ;
    }

    $catalog->close();
    $self->changeStatus("STARTED","RUNNING",0,$self->{HOST},$self->{PORT});    
    return 1;
}

#
## Called from requestJob. Fetches the JDL
## 
sub GetJDL {
  my $self = shift;

  $self->info("The job agent asks for a job to do:");

  my $jdl;
  my $i=$ENV{ALIEN_JOBAGENT_RETRY} || 1;

  my $result;
  if ($ENV{ALIEN_PROC_ID}){
    $self->info("ASKING FOR ANOTHER JOB");
    $self->putJobLog("trace","Asking for a new job");
  }

    while(1) 
    {
        $self->info("Getting the jdl from the clusterMonitor, agentId is $ENV{ALIEN_JOBAGENT_ID}...");

        #my $hostca=$self->getHostClassad();
        my $hostca = $self->{WN_JDL};


        if (!$hostca)
        {
            $self->sendJAStatus('ERROR_HC');
            #$catalog and  $catalog->close();
            return;
        }

        my $hostca_stage;

        #   if ($catalog){
        #     $self->info("We have a catalog (we can stage)");
        #     $hostca_stage=$hostca;
        #     $hostca_stage=~ s/\[/\[TO_STAGE=1;/;
        #   }

        $self->sendJAStatus(undef, {TTL=>$self->{TTL}});

        my $done = $self->{SOAP}->CallSOAP("CLUSTERMONITOR","getJobAgent", $ENV{ALIEN_JOBAGENT_ID}, 
                                            "$self->{HOST}:$self->{PORT}", $self->{CONFIG}->{ROLE}, $hostca, $hostca_stage);
        my $info;
        $done and $info=$done->result;

        if ($info)
        {
            $self->info("Got something from the ClusterMonitor");
            #      $self->checkStageJob($info, $catalog);
            if (!$info->{execute})
            {
	            $self->info("We didn't get anything to execute");
            }	
            else
            {
                my @execute=@{$info->{execute}};
                $result=shift @execute;

                if ($result eq "-3") 
                {
    	            $self->sendJAStatus('INSTALLING_PKGS');
                    $self->{SOAP}->CallSOAP("Manager/Job", "setSiteQueueStatus",$self->{CONFIG}->{CE_FULLNAME},"jobagent-install-pack");
                    $self->info("We have to install some packages (@execute)");

                    foreach (@execute)
                    {
            	        my ($ok, $source)=$self->installPackage( $_);

    	                if (! $ok)
                        {
                	        $self->info("Error installing the package $_");
                            $self->sendJAStatus('ERROR_IP');
                            # $catalog and $catalog->close();
                            #
                     	    return;
            	        }
	                }
          
                    $i++; #this iteration doesn't count
                }
                elsif ( $result eq "-2")
                {
                    $self->info("No jobs waiting in the queue");
                }
                else
                {
                    $self->{SOAP}->CallSOAP("Manager/Job", "setSiteQueueStatus",$self->{CONFIG}->{CE_FULLNAME},"jobagent-matched");
                    last;
                }
            }
        }
        else
        {
            $self->info("The clusterMonitor didn't return anything");
        }

        --$i or  last;
        print "We didn't get the jdl... let's sleep and try again\n";
        $self->{SOAP}->CallSOAP("Manager/Job", "setSiteQueueStatus",$self->{CONFIG}->{CE_FULLNAME},"jobagent-no-match", $hostca);
        sleep (30);
        if($self->{MONITOR})
        {
            $self->{MONITOR}->sendBgMonitoring();
        }

        $self->sendJAStatus('REQUESTING_JOB');
    }
#  $catalog and  $catalog->close();

  $result or $self->info("Error getting a jdl to execute");
  ( UNIVERSAL::isa( $result, "HASH" )) and $jdl=$result->{jdl};
  if (!$jdl) 
  { 
    $self->info("Could not download any  jdl!");
    $self->sendJAStatus('ERROR_GET_JDL');
    return;
  }

  my $queueid=$ENV{ALIEN_PROC_ID}=$self->{QUEUEID}=$result->{queueid};
  my $token=$ENV{ALIEN_JOB_TOKEN}=$result->{token};
  $self->{JOB_USER} = $result->{user};

  my $message="The job has been taken by the jobagent $ENV{ALIEN_JOBAGENT_ID}";
  $ENV{EDG_WL_JOBID} and $message.="(  $ENV{EDG_WL_JOBID} )";
  if (  $ENV{LSB_JOBID} )
  {
     $message.=" (LSF ID $ENV{LSB_JOBID} )";
     $self->sendJAStatus(undef, {LSF_ID=>$ENV{LSB_JOBID}});
  }

  $self->putJobLog("trace",$message);


  $self->info("ok\nTrying with $jdl");

  $self->{CA} = Classad::Classad->new("$jdl");
  my $tt  = $self->{CA}->isOK();
  $self->info ("Is ok? : $tt \n");

  ( $self->{CA}->isOK() ) and return 1;

  $self->info ("Why here ??? \n");

  $jdl =~ s/&amp;/&/g;
  $jdl =~ s/&amp;/&/g;

  $self->info("Trying again... ($jdl)");
  $self->{CA} = Classad::Classad->new("$jdl");
  ( $self->{CA}->isOK() ) and return 1;

  $self->sendJAStatus('ERROR_JDL');
  return;
}

#
# overwrite _getInputFile (remove -l option), otherwise 'get' complains 
sub _getInputFile {
  my $self=shift;
  my $catalog=shift;
  my $lfnName=shift;
  my $pfn=shift;

  $self->putJobLog("trace","Downloading input file: $lfnName");
  $self->info( "Getting $lfnName");


  my $options="-silent";

  for (my $i=0;$i<2;$i++) {
#    $catalog->execute("get", "-l", $lfnName,$pfn, $options ) and return 1;
     $catalog->execute("get", $lfnName,$pfn, $options ) and return 1;

    $options="";
    $self->putJobLog("trace","Error downloading input file: $lfnName (trying again)");

  }
  $self->putJobLog("error","Could not download the input file: $lfnName (into $pfn)");

  return;
}

#
# overwrite CreateDirs so that 1) old directories are not removed and 2) relative name of working directory is kept in $self
sub CreateDirs 
{
  my $self=shift;
  my $done=1;

  my $guid = new Copilot::GUID;    
  $self->{WORKDIR_RELATIVE_PATH} = "/alien-job-$ENV{ALIEN_PROC_ID}-".$guid->CreateGuid();

  $self->{WORKDIR} =~ s{(/alien-job-\d+)?\/?$}{$self->{WORKDIR_RELATIVE_PATH}};

  $ENV{ALIEN_WORKDIR} = $self->{WORKDIR};

  my @dirs=($self->{CONFIG}->{LOG_DIR},
	    "$self->{CONFIG}->{TMP_DIR}/PORTS", $self->{WORKDIR},
	    "$self->{CONFIG}->{TMP_DIR}/proc/");


  foreach my $fullDir (@dirs){
    my $dir = "";
    (-d  $fullDir) and next;
    foreach ( split ( "/", $fullDir ) ) {
      $dir .= "/$_";
      mkdir $dir, 0777;
    }
  }

  $self->putJobLog("trace","Creating the working directory $self->{WORKDIR}");

  if ( !( -d $self->{WORKDIR} ) ) {
    $self->putJobLog("error","Could not create the working directory $self->{WORKDIR} on $self->{HOST}");
  }

  # check the space in our workind directory
#  my $handle=Filesys::DiskFree->new();
#  $handle->df();
#  my $space=$handle->avail($self->{WORKDIR});
#  my $freemegabytes=int($space/(1024*1024));
#  $self->info("Workdir has $freemegabytes MB free space");

#  my ( $okwork, @workspace ) =
#      $self->{CA}->evaluateAttributeVectorString("Workdirectorysize");
#  $self->{WORKSPACE}=0;
#  if ($okwork) {
#    if (defined $workspace[0]) {
#      my $unit=1;
#      ($workspace[0] =~ s/KB//g) and $unit = 1./1024.;
#      ($workspace[0] =~ s/MB//g) and $unit = 1;
#      ($workspace[0] =~ s/GB//g) and $unit = 1024;

#      if (($workspace[0]*$unit) > $freemegabytes) {
#	# not enough space
#	$self->putJobLog("error","Request $workspace[0] * $unit MB, but only $freemegabytes MB free in $self->{WORKDIR}!");
#	$self->registerLogs(0);
#	$self->changeStatus("%", "ERROR_IB");
#	$done=0;
#      } else {
#	# enough space
#	$self->putJobLog("trace","Request $workspace[0] * $unit MB, found $freemegabytes MB free!");
#	$self->{WORKSPACE}=$workspace[0]*$unit;
#      }
#    }
#  }

  return $done;
}


"M";

