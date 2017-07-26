#!perl
$\=$/;

use strict;

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;

use JSON;
use Config::JSON;
use REST::Client;

use Centrifugo::Client;

my $PING_INTERVAL=3;
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
		print "MESSAGE: ".encode_json $infoRef->{data};
		if ($infoRef->{data}->{message} eq 'COMMAND') {
			# ACK to console (via ACK PHP)					
			serverAck( $SERVER_BASE_API  );
		}
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
			serverPing( $SERVER_BASE_API , $HOST_ID );
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
	my $token = $_=$client->responseContent();
	s/^/     < /mg;
	print;
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

# TODO
# TODO
# TODO   Ce n'est pas le PING qui devrait envoyer les infos sur le client_id à la console, mais un ordre notify.php. Sinon, on a toujours
#        un PING de retard
# TODO
# TODO

sub serverPing {
	my ($API)=@_;
	my $client = REST::Client->new();
	$client->setHost($API);
	my $CLIENT_ID = $centrifugoClientHandle ? $centrifugoClientHandle->client_id() : '';
	my $POST = qq!api-key=${API_KEY}&host-id=${HOST_ID}&client-id=${CLIENT_ID}!;
	$client->POST("/ping.php", $POST, { 'Content-type' => 'application/x-www-form-urlencoded'});
	print "POST > $POST";
	print "     < (".$client->responseCode().')';
	my $pingResponse = $_=$client->responseContent();
	s/^/     < /mg;
	print;
	if ($client->responseCode() eq 200) {
		processServerCommand($pingResponse);
	}
}

sub serverAck {
	my ($API)=@_;
	my $client = REST::Client->new();
	$client->setHost($API);
	my $CLIENT_ID = $centrifugoClientHandle->client_id();
	my $POST = qq!api-key=${API_KEY}&host-id=${HOST_ID}&client-id=${CLIENT_ID}!;
	$client->POST("/ack.php", $POST, { 'Content-type' => 'application/x-www-form-urlencoded'});
	print "ACK > $POST";
	print "    < (".$client->responseCode().')';
}

# This takes the output of ping sent to the server, and interprets them as command if possible
sub processServerCommand {
	$_ = shift;print "centrifugoClientHandle=$centrifugoClientHandle";
	if (/^LISTEN ON/ && not defined $centrifugoClientHandle) {
		print "received command : LISTEN ON : listening";
		makeEventListening();	
	}
	if (/^LISTEN OFF/ && defined $centrifugoClientHandle) {
		print "received command : LISTEN OFF : closing connection";
		$centrifugoClientHandle->disconnect();
	}
}