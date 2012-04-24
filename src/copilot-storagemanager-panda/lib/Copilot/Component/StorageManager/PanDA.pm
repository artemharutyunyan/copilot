package Copilot::Component::StorageManager::PanDA;

=head1 NAME Copilot::Component::StorageManager::PanDA

=head1 DESCRIPTION

This class implements the StorageAdapter for atlas. It is a child class of Copilot::Component (for general information 
about the components in Copilot please refer to Copilot::Component documentation). The component must be instantiated within one of 
the component containers (e.g. Copilot::Container::XMPP). The following options must be provided during 
instantiation via 'ComponentOptions' parameter:

    ChirpDir               - Directory where the job manager should put the job files and create chirp access control list 
                             files, so the agents can access them
    StorageManagerAddress  - The address (Jabber ID) of the storage manager where some of the requests are redirected 

    Exmaple of JobManager instantiation:
    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'StorageManager::PanDA',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ComponentOptions => {
                                                                    ChirpDir => $chirpWorkDir ,
                                                                    StorageManagerAddress => $storageManagerJID,
								    PandaDataMover => $data_mover,
								    # Redis and user should go here
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
#use Copilot::GUID;

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
    POE::Session->create (
                            inline_states => {
                                                _start => \&mainStartHandler,
                                                _stop  => \&mainStopHandler,
                                                $self->{'COMPONENT_INPUT_HANDLER'} => \&componentInputHandler,
                                                componentProcessInput              => \&componentProcessInputHandler,
                                                #componentStoreJob                  => \&componentStoreJobHandler,
                                                #componentWantGetJob                => \&componentWantGetJobHandler,
                                                #componentGetJob                    => \&componentGetJobHandler,

                                                componentGetJobOutputDir => \&componentGetJobOutputDirHandler,
                                                componentError => \&componentErrorHandler,
                                                #componentNoJob => \&componentNoJobHandler,
                                                #componentSendJob => \&componentSendJobHandler,
                                                #componentSaveJob => \&componentSaveJobHandler,
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
    $self->{'JOB_WORKDIR'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpDir'} || die "Chirp server directory is not provided.\n"); 

    # Event in server, which handles the messages sent from component to the outer world
    ($self->{'SEND_HANDLER'} = $options->{'CONTAINER_SEND_HANDLER'})
        or die "CONTAINER_SEND_HANDLER is not specified. Can't communicate with the container.\n"; 

    # Storage manager to redirect output requests to
    $self->{'STORAGE_MANAGER_ADDRESS'} = ($options->{'COMPONENT_OPTIONS'}->{'StorageManagerAddress'} or die "Storage manager address is not given.\n");        

    # user which runs the panda data move
    $self->{'PANDA_DATA_MOVER'} = ($options->{'COMPONENT_OPTIONS'}->{'PandaDataMover'} or die "Panda Data Moiver is not given.\n");
    # chirp  
    $self->{'CHIRP_HOST'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpServer'} || die "Chirp server address is not provided.\n");
    $self->{'CHIRP_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'ChirpPort'} || die "Chirp port is not provided.\n");

    #redis
    $self->{'REDIS_HOST'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisServer'} || die "Redis server address is not provided\n");
    $self->{'REDIS_PORT'} = ($options->{'COMPONENT_OPTIONS'}->{'RedisPort'}   || die "Redis port address is not provided\n");
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

    if ($input->{'command'} eq 'storeJob')
    {
        $kernel->yield ('componentStoreJob', $input);
        $kernel->post($container, $logHandler, 'Got job submission');  
    }
    elsif ($input->{'command'} eq 'want_getJob')
    {
        $kernel->yield ('componentWantGetJob', $input);
        $kernel->post ($container, $logHandler, 'Got the "want job" request');
    } 
    elsif ($input->{'command'} eq 'getJob')
    {
        $kernel->yield ('componentGetJob', $input);
        $kernel->post ($container, $logHandler, 'Got the real job request');
    }
    elsif ($input->{'command'} eq 'getJobOutputDir')
    {
        my $jobID = $input->{'jobID'};
        $kernel->yield ('componentGetJobOutputDir', $input);
        $kernel->post  ($container, $logHandler, "Agent asking for the output dir for the job (ID: $jobID)");
    }
    elsif ($input->{'command'} eq 'jobDone')
    {
        my $jobID = $input->{'jobID'};
        $kernel->yield ('componentJobDone', $input);
        $kernel->post ($container, $logHandler, "Agent finished the job (ID: $jobID)");
    }
    

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
    my $agentHost = $input->{'agentHost'};
    my $puser=$self->{'PANDA_DATA_MOVER'};
    my $upload_data_cmd='su - '.$puser.' -c "copilot-panda-data-mover -j '.$jobID." -H ".$agentHost.'"';
    my $ret=system($upload_data_cmd);
    
    if($ret==0)
    {
    	$kernel->post ($container, $logHandler, "output files of Job $jobID has been uploaded and registered successfully");
    }	
    else
    {
	kernel->post ($container, $logHandler, "output files of Job $jobID failed to upload and register");
    }	


    # add redirection information
    #   $input->{'referral'} = $self->{'STORAGE_MANAGER_ADDRESS'};   
   
    #my $to = $input->{'from'};
    #delete ($input->{'from'});    
    
    #my $storageRef = {
    #                    'to'   => $to,
    #                    'info' => {
    #                                'command'  => 'redirect',
    #                                'referral' => $self->{'STORAGE_MANAGER_ADDRESS'}, 
    #                                'info'     => $input,     
    #                              }, 
    #                 };   
    # see if there is something we need to pass back to the container
    #defined ($input->{'send_back'}) and ($storageRef->{'send_back'} =  $input->{'send_back'});

    #$kernel->post ($container, $logHandler, 'Redriecting jobagent (Job ID: '. $jobID .' to the storage manager ('. $self->{'STORAGE_MANAGER_ADDRESS'}.')' );
    #$kernel->post ($container, $sendHandler, $storageRef);              
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

"M";
