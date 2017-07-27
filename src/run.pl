#!perl
$\=$/;

use strict;

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;

use JSON;
use Config::JSON;
use REST::Client;

use Centrifugo::Client;

my $PING_INTERVAL=10;
our $CONFIG="/tmp/config.json";
our $SERVER_BASE_API=$ENV{"DMON_API"};
our $CENTRIFUGO_WS=$ENV{"CENT_WS"};

my $API_KEY = "key-123";

my $USER_ID = "First_User_12345";
my $TIMESTAMP = time();
my $TOKEN;

our $HOST_ID;

our $mainEventLoop;
our $centrifugoClientHandle;


# Initialize the monitor
init();

# Ask for a client token
$TOKEN = askForToken($USER_ID,$TIMESTAMP);

# Connects to Centrifugo
makeEventListening();

# Start the event loop
AnyEvent->condvar->recv;
exit;



###########################################################
#   makeEvent* subs are launching tasks in the event loop

sub makeEventListening {
	$centrifugoClientHandle = Centrifugo::Client->new("$CENTRIFUGO_WS/connection/websocket",
		debug => 'true',
		ws_params => {
			ssl_no_verify => 'true',
			timeout => 600
	});

	$centrifugoClientHandle->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	) -> on('connect', sub{
		my ($infoRef)=@_;
		print "Connected to Centrifugo version ".$infoRef->{version};
		
		# When connected, client_id() is define, so we can subscribe to our private channel
		$centrifugoClientHandle->subscribe( '&'.$centrifugoClientHandle->client_id() );
				
		# For now : loop and ping the server every 10 s
		makeEventPingServerEvery($PING_INTERVAL);
		
	})-> on('message', sub{
		my ($infoRef)=@_;
		processServerCommand($infoRef->{data});
	})-> on('disconnect', sub {
		undef $centrifugoClientHandle;
	});
}

# Creates an event to ping the server every X minutes
sub makeEventPingServerEvery {
	my $interval = shift;
	$mainEventLoop = AnyEvent->timer(
		after => 0,
		interval => $interval,
		cb => sub {
			my $response = sendServerNotification( 'PING', { } );
			processServerJsonCommand($response) if $response;
		}
	);
}

sub askForToken {
	my ($user,$timestamp)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	
	my $POST = qq!user=$user&timestamp=$timestamp!;
	$client->POST("/token.php", $POST, { 'Content-type' => 'application/x-www-form-urlencoded'});
	print "POST > $POST";
	print "     < (".$client->responseCode().')';
	my $token =my $tokenOutput=$client->responseContent();
	$tokenOutput=~s/^/     < /mg;
	print $tokenOutput;
	if ($client->responseCode() eq 200) {
		return($token);
	}
	print "ERROR < No websocket token";
}

###########################################################

sub init {
	my $config = openOrCreateConfigFile();	
	$HOST_ID = $config->get('host_id');
	unless ($HOST_ID) {
		$HOST_ID = `hostname`;
		chomp $HOST_ID;
		$config->set('host_id',$HOST_ID);
	}
}

sub openOrCreateConfigFile {
	if (-f $CONFIG) {
		return Config::JSON->new($CONFIG);
	} else {
		print STDERR "Config file $CONFIG not found : Creating...";
		return  Config::JSON->create($CONFIG);
	}
}

# Sends a notification to the server. The parameter is a HashRef (api-key, host-id and client-id parameters will be added here)
sub sendServerNotification {
	my ($type, $dataHRef)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	my $CLIENT_ID = $centrifugoClientHandle ? $centrifugoClientHandle->client_id() : undef;
	$dataHRef->{ 't' }=$type;
	$dataHRef->{ 'api-key' }=$API_KEY;
	$dataHRef->{ 'client-id' }=$CLIENT_ID;
	$dataHRef->{ 'host-id' }=$HOST_ID;
	my $POST = encode_json $dataHRef;
	$client->POST("/msg.php", $POST, { 'Content-type' => 'application/json'});
	print "$type > $POST";
	print "    < (".$client->responseCode().')';
	my $response=my $resOutput=$client->responseContent();
	if ($response) {
		$resOutput=~s/^/    < /mg;
		print $resOutput;
	}
	return $response;
}

# This takes a command expressed in JSON, sends a ACK to the server, then executes the command and
# sends the result back to the server
# The struct for a command is :
# { "t":"CMD", "id":"CmdID", "cmd":"...", "args":{...} }
# The struct for a ACK/Notification is :
# { "t":"ACK", "id":"CmdID" } or if the JSON is invalid : { "t":"ACK", "id":null, "message":"..." }
# the struct for a result is :
# { "t":"RESULT", "id":"CmdID","status":"0-4", ["message":"...",] ["retcode":"...",] ["STDOUT":"...",] ["STDERR":"..."] }  
#    (status code values are Nagios-compliant : 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN, 4=PENDING)
#     a value of 4(PENDING) means that the command is NOT finished, and that other messages will follow (partial result)
sub processServerJsonCommand {
	my ($jsonCmd) = shift;
	my $command = 
		eval {
			decode_json $jsonCmd;
		} or do {
			my $error = $@;
			sendServerNotification( 'ACK', { id => undef, message => $error });
			return;
		};
		
	processServerCommand($command);
}

sub processServerCommand {
	my ($command) = shift;
	# Envoi d'un ACK
	my $cmdId = $command->{id};
	sendServerNotification( 'ACK', { id => $cmdId });

	# Traitement de la commande
	my $cmd = $command->{cmd};
	
	print "Received a command : $cmd";
	
	my $args = $command->{args};
	# List of known commands :   RUN
	if ('RUN' eq uc $cmd) {
		processRunCommand($cmdId, $args);
	}
	
	if (/^LISTEN ON/ && not defined $centrifugoClientHandle) {
		print "received command : LISTEN ON : listening";
		makeEventListening();	
	}
	if (/^LISTEN OFF/ && defined $centrifugoClientHandle) {
		print "received command : LISTEN OFF : closing connection";
		$centrifugoClientHandle->disconnect();
	}
}

# Execute a system command.
# Output 4 values :
# status (0=OK, 2=Error while running command)
# retCode : return code of the command
# stdout, stderr
sub executeCommand {
	my ($cmdline)=@_;
	use IPC::Open3;
	my $status=0; # OK
	my $retval=0;
	my $stdout="";
	my $stderr="";
	my $pid = eval {
		open3(\*WRITER, \*READER, \*ERROR, $cmdline);
	} or do {
		$status=2; # CRITICAL
		$stderr=$@;
		$stderr=~s/^open3: +//;
		0;
	}; 
	if ($pid) {
		my $line;
		$stdout.=$line while $line=<READER>;
		$stderr.=$line while $line=<ERROR>;
		waitpid( $pid, 0 ) or warn "$!";
		$retval = $?;
	}
	return ($status, $retval, $stdout, $stderr);
}
###################### COMMANDS #######################

# RUN
# ARGS : cmdline
sub processRunCommand {
	my ($cmdId, $args)=@_;
	my $cmdline = $args->{cmdline};
	print "RUN[$cmdId]:$cmdline";
	my($status,$retval,$stdout,$stderr) = executeCommand($cmdline);
	my @stdout = split /\n/,$stdout;
	my @stderr = split /\n/,$stderr;
	sendServerNotification('RESULT', {
		id => $cmdId,
		cmdline => $cmdline,
		status => $status,
		stdout => \@stdout,
		stderr => \@stderr,
		retcode => $retval
	});
}

