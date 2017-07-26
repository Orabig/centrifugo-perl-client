#!perl
$\=$/;

use strict;

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;

use JSON;
use Config::JSON;
use REST::Client;

our $CONFIG="/tmp/config.json";
our $SERVER_BASE_API=$ENV{"DMON_API"};
our $CENTRIFUGO_WS=$ENV{"CENT_WS"};

my $API_KEY = "key-123";

my $USER_ID = "First_User_12345";
my $TIMESTAMP = time();
my $TOKEN;



our $HOST_ID;
our $CLIENT_ID;

our $webSocketHandle;
our $mainEventLoop;



# Initialize the monitor
init();

# Ask for a client token
$TOKEN = askForToken($USER_ID,$TIMESTAMP);

# For now : loop and ping the server every 10 s
makeEventPingServerEvery(10);

# Start the event loop
AnyEvent->condvar->recv;

###########################################################
#   makeEvent* subs are launching tasks in the event loop

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

#
sub makeEventListening {
	AnyEvent::WebSocket::Client -> new(
		ssl_no_verify => 'true',
		timeout => 600
		) -> connect("$CENTRIFUGO_WS/connection/websocket") -> cb(sub {

		$webSocketHandle = eval { shift->recv };
		if($@) {
			# handle error...
			warn $@;
			return;
		}
		
		# Send CONNECT message
		my $CONNECT=encode_json {
			UID => 'anyId',
			method => 'connect',
			params => {
				user => $USER_ID,
				timestamp => "$TIMESTAMP", # this MUST be a string
				token => $TOKEN
			}
		};
		print "WEBSOCKET > $CONNECT";
		$webSocketHandle->send($CONNECT);

		# receive message from the websocket...
		$webSocketHandle->on(each_message => sub {
			my($loop, $message) = @_;
			print "WEBSOCKET < ".$message->{body};
			my $body = decode_json($message->{body});
			if ($body->{method} eq 'connect') {
				# onConnect => SUBSCRIBE CHANNEL
				
				$CLIENT_ID = $body->{body}->{client};
				print "Connected to WS : CLIENT_ID='$CLIENT_ID'";
				my $SUBSCRIBE = encode_json {
					UID => 'anyId',
					method => 'subscribe',
					params => { channel => "&".$CLIENT_ID }
				};
				print "WEBSOCKET > $SUBSCRIBE";
				$webSocketHandle->send($SUBSCRIBE);
				
			} elsif ($body->{method} eq 'message') {
				# onMessage
				
				my $message = $body->{body}->{data};
				print "GOT a message : ".encode_json $message;
				if ($message->{message} eq 'COMMAND') {
					# ACK to console (via ACK PHP)					
					serverAck( $SERVER_BASE_API  );
				}
				
			} elsif ($body->{method} eq 'subscribe') {
				# onSubscribe
			} #...
		});
		
		$webSocketHandle->on(parse_error => sub {
			my($loop, $error) = @_;
			print "ERROR:$error";
		});

		# handle a closed connection...
		$webSocketHandle->on(finish => sub {
			my($loop) = @_;
			print "Connection closed";
			undef $webSocketHandle;
			$CLIENT_ID='';
		});

	});
	
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
	
	my $POST = qq!api-key=${API_KEY}&host-id=${HOST_ID}&client-id=${CLIENT_ID}!;
	$client->POST("/ack.php", $POST, { 'Content-type' => 'application/x-www-form-urlencoded'});
	print "ACK > $POST";
	print "    < (".$client->responseCode().')';
}

# This takes the output of ping sent to the server, and interprets them as command if possible
sub processServerCommand {
	$_ = shift;
	if (/^LISTEN ON/ && not defined $webSocketHandle) {
		print "received command : LISTEN ON : listening";
		makeEventListening();	
	}
	if (/^LISTEN OFF/ && defined $webSocketHandle) {
		print "received command : LISTEN OFF : closing connection";
		$webSocketHandle->close();
	}
}