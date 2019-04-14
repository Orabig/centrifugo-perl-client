package Centrifugo::Client;

our $VERSION = "2.0_alpha";

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(generate_token);

use Carp qw( croak );
use AnyEvent::WebSocket::Client 0.40;

use AnyEvent::HTTP;
use JSON;

=head1 NAME

Centrifugo::Client

=head1 SYNOPSIS

 use Centrifugo::Client;
 use AnyEvent;

 my $cclient = Centrifugo::Client->new("$CENTRIFUGO_WS/connection/websocket");

 $cclient -> on('connect', sub{
		my ($infoRef)=@_;
		print "Connected to Centrifugo version ".$infoRef->{version};		
	}) -> on('message', sub{
		my ($infoRef)=@_;
		print "MESSAGE: ".encode_json $infoRef->{data};

	}) -> connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	);
	
 $cclient->subscribe( channel => 'my-channel&' );
 $cclient->subscribe( channel => 'public-channel' );
 $cclient->subscribe( channel => '$private' );

 # Now start the event loop to keep the program alive
 AnyEvent->condvar->recv;
	
=head1 DESCRIPTION

This library allows to communicate with Centrifugo through a websocket.

=cut

use strict;
use warnings;


=head1 FUNCTION new

	my $client = Centrifugo::Client->new( $URL );

or

	my $client = Centrifugo::Client->new( $URL,
	   debug => 'true',          # If true, some informations are written on STDERR
	   debug_ws => 'true',       # If true, all web socket messages are written on STDERR
	   authEndpoint => "...",    # The full URL used to ask for a key to subscribe to private channels
	   max_alive_period => 30,   # interval (in s) since last communication with server that triggers a PING (default 0)
	   refresh_period => 5,      # Check frequency for max_alive_period (default 10s)
	   retry => 0.5 ,            # interval (in ms) between reconnect attempts which value grows exponentially (default 1.0)
	   max_retry => 30,          # upper interval value limit when reconnecting. (default 30)
	   resubscribe => 'true',    # automatic resubscribing on subscriptions (default: 'true')
	   recover => 'true',        # Recovers the lost messages after a reconnection (default: 'false')
	   ws_params => {            # These parameters are passed to AnyEvent::WebSocket::Client->new(...)
			 ssl_no_verify => 'true',
			 timeout => 600
		  },
	   );

=cut

sub new {
	my ($class, $ws_url, %params)=@_;
	my $this = {};
	bless($this, $class);
	$this->{WS_URL} = $ws_url;
	$this->{DEBUG} = $params{debug} && $params{debug}!~/^(0|false|no)$/i; delete $params{debug};
	$this->{DEBUG_WS} = $params{debug_ws} && $params{debug_ws}!~/^(0|false|no)$/i; delete $params{debug_ws};
	$this->{AUTH_URL} = delete $params{authEndpoint} || "/centrifuge/auth/";
	$this->{WEBSOCKET} = AnyEvent::WebSocket::Client -> new( %{$params{ws_params}} ); delete $params{ws_params};
	$this->{MAX_ALIVE} = delete $params{max_alive_period} || 0;
	$this->{REFRESH} = delete $params{refresh_period} || 10;
	$this->{RETRY} = delete $params{retry} || 1;
	$this->{MAX_RETRY} = delete $params{max_retry} || 30;
	$this->{RESUBSCRIBE} = ! defined $params{resubscribe} || $params{resubscribe}!~/^(0|false|no)$/i; delete $params{resubscribe};
	$this->{RECOVER} = $params{recover} && $params{recover}!~/^(0|false|no)$/i; delete $params{recover};
	$this->{_id} = 1;        # Unique incremental message id
	$this->{_requests} = {}; # Pending requests by ID. When requests have received a result/error, they are removed from this hash
	croak "Centrifugo::Client : Unknown parameter : ".join',',keys %params if %params;
	return $this;
}

=head1 FUNCTION connect - send authorization parameters to Centrifugo so your connection could start subscribing on channels.

$client->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN,
		[info => $info,]
		[uid => $uid,]
		);

This function retuns $self to allow chains of multiple function calls.
		
It is possible to provide a UID for this command, but if you don't, a random one will be generated for you and cannot be retrieved afterward.

=cut

sub connect {
	my ($this,%PARAMS) = @_;
	croak("Missing user in Centrifugo::Client->connect(...)") if ! $PARAMS{user};
	croak("Missing timestamp in Centrifugo::Client->connect(...)") if ! $PARAMS{timestamp};
	croak("Missing token in Centrifugo::Client->connect(...)") if ! $PARAMS{token};
	# Fix parameters sent to Centrifugo
	$PARAMS{timestamp}="$PARAMS{timestamp}" if $PARAMS{timestamp}; # This MUST be a string
	# Save the Centrifugo connection parameters
	$this->{_cnx_uid} = delete $PARAMS{uid} || _generate_random_id();
	$this->{_cnx_params} = \%PARAMS;
	
	# Connects to Websocket
	$this->_reset_reconnect_sequence();
	$this->_connect();
	return $this;
}

# This function (re)connects to the websocket
sub _connect {
	my ($this) = @_;
	$this->_debug( "INFO : Centrifugo::Client : Connecting to $this->{WS_URL}" );
	$this->{WEBSOCKET}->connect( $this->{WS_URL} )->cb(sub {
		$this->{WSHANDLE} = eval { shift->recv };
		if ($@) {
		# Todo : Vérifier l'appel à cette fonction, la signature a changé
			$this->_on_error($@);
			$this->_reconnect();
			return;
		}
		# The websocket connection is OK
		$this->_on_ws_connect();
	});
}

# This function is called when client is connected to the WebSocket
sub _on_ws_connect {
	my ($this) = @_;
	$this->_debug( "INFO : Centrifugo::Client : WebSocket connected to $this->{WS_URL}" );
	
	# define the callbacks
	$this->{WSHANDLE}->on(each_message => sub { $this->_on_ws_message($_[1]) });
	$this->{WSHANDLE}->on(finish => sub { $this->_on_close(($_[0])->close_reason()) });
	$this->{WSHANDLE}->on(parse_error => sub {
		my($cnx, $error) = @_;
		$this->_debug( "ERROR: Centrifugo::Client : $error" );
		$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
	});
	
	# Then, connects to Centrifugo
	$this->_send_message( {
		method => 'connect',
		params => $this->{_cnx_params}
	} );
}

# This function is called when client is connected to Centrifugo
sub _on_connect {
	my ($this, $request, $body) = @_;
	$this->_debug( "INFO : Centrifugo::Client : Connected to Centrifugo : ".encode_json $body );	
	# on Connect, the client_id must be read (if available)
	if ($body && ref($body) eq 'HASH' && $body->{client}) {
		$this->{CLIENT_ID} = $body->{client};
		$this->_debug( "INFO : Centrifugo::Client : CLIENT_ID=".$this->{CLIENT_ID} );
	}
	$this->_init_keep_alive_timer() if $this->{MAX_ALIVE};
	$this->_reset_reconnect_sequence();
	$this->_resubscribe() if $this->{RESUBSCRIBE};
}

# This function is called when client receives a message
sub _on_message {
	my ($this, $body) = @_;
	my $uid = $body->{uid};
	my $channel = $body->{channel};
	$this->_debug( "INFO : Centrifugo::Client : Message from $channel : ".encode_json $body->{data} );
}

# This function is called when client has been subscribed in a channel
sub _on_subscribe {
	my ($this, $request, $body) = @_;
	my $channel = $request->{channel};
	$this->_debug( "INFO : Centrifugo::Client : Subscribed to $channel : ".encode_json $body );
	# READ SPECS : should hand expires, tltl, recoverable, seq, gen, epoch, publications
	if ($body->{recovered} && $body->{recovered} == JSON::true) {
		# Re-emits the lost messages
		my $messages = $body->{publications};
		foreach my $message (reverse @$messages) {
			my $sub = $this->{ON}->{message};
			$this->_debug( "TODO : je dois tester si j'envoie le bon niveau : ".encode_json $message);
			$sub->($channel, $message) if $sub;
		}
	}
	# Keeps track of channels
	$channel=~s/&.*/&/; # Client channel boundary
	$this->{_channels}->{ $channel } = $body;
	$this->{_subscribed_channels}->{ $channel } = 1; # TEST if it worked
	delete $this->{_pending_subscriptions}->{ $channel };
}

# This function is called when client is connected to Centrifugo
sub _on_unsubscribe {
	my ($this, $request, $body) = @_;
	my $channel = $request->{channel};
	$this->_debug( "INFO : Centrifugo::Client : Unsubscribed from $channel : ".encode_json $body );
	# Keeps track of channels
	$channel=~s/&.*/&/; # Client channel boundary
	delete $this->{_channels}->{ $channel };	
	delete $this->{_subscribed_channels}->{ $channel };
	delete $this->{_pending_subscriptions}->{ $channel };
}

# This function automatically reconnects to channels
sub _resubscribe {
	my ($this) = @_;
	foreach my $channel (keys %{$this->{_channels}}) {
		$this->_debug( "INFO : Centrifugo::Client : Resubscribe to $channel" );
		$channel=~s/&.*/&/; # Client channel boundary
		my $params = {
			channel => $channel
		};
		# Useless in V2
#		if ($this->{RECOVER} && $this->{_channels}->{$channel}->{last}) {
#			$params->{recover}=JSON::true;
#			$params->{last}=$this->{_channels}->{$channel}->{last}; 
#		}
		$this->subscribe( %$params );
	}
}

# This function is called when the connection with server is lost
sub _on_close {
	my ($this, $message) = @_;
	$message="(none)" unless $message;
	$this->_debug( "WARN : Centrifugo::Client : Connection closed, reason=$message" );
	$this->{ON}->{'ws_closed'}->($message) if $this->{ON}->{'ws_closed'};
	undef $this->{_alive_handler};
	undef $this->{WSHANDLE};
	undef $this->{CLIENT_ID};
	delete $this->{_subscribed_channels};
	delete $this->{_pending_subscriptions};
	$this->_reconnect();
}

# This function is called if an errors occurs with the server
sub _on_error {
#	my ($this, @infos) = @_;
	my ($this, $infos) = @_;
	warn "Error in Centrifugo::Client : ".encode_json($infos);
	$this->{ON}->{'error'}->($infos) if $this->{ON}->{'error'};
}

# This function is called once for each message received from Centrifugo
sub _on_ws_message {
	my ($this, $message) = @_;
	$this->_debug_ws("INFO : WebSocket : Rcvd < $message->{body}");
	$this->{_last_alive_message} = time();
	# TODO : expect to have multiple lines here (thus multiple "fullbody" objects)
	# See specs at https://centrifugal.github.io/centrifugo/server/protocol/
	my @message_parts = split "\n", $message->{body};
	foreach my $body (@message_parts) {
		my $info = decode_json($body); # The body of websocket message
		my $result = $info->{result};
		my $error = $info->{error};
		if ($error) {
			$this->_on_error( $error );		
		} else {
			# Get the request that was sent if there is one (message have no associated request)
			my $id = $info->{id};
			my $method;
			if ($id) {
				# When the message has an ID, this is a reply to a request
				my $request = delete $this->{_requests}->{ $id };
				my $method = $request->{method};
				$this->_on_connect( $request->{params}, $result ) if $method eq 'connect';
				$this->_on_subscribe( $request->{params}, $result ) if $method eq 'subscribe';
				$this->_on_unsubscribe( $request->{params}, $result ) if $method eq 'unsubscribe';
				# Call the client callback of the method
				my $sub = $this->{ON}->{$method};
				$sub->( $result ) if ($sub);
			} else {
				# When the message has no ID, this is a publication
				my $channel = $result->{channel};
				my $type = $result->{type}; # undef/1/2/3 for message/join/leave/unsub
				my $data = $result->{data};
				$type=0 unless $type;
				my @TYPES=qw( message join leave unsub );
				my $method=$TYPES[$type];
				# Call the callback of the method
				my $sub = $this->{ON}->{$method};
				$sub->( $channel, $data ) if ($sub);
			}

			
		}
	}
}

# Inits the Fibonacci sequence for reconnection retries
sub _reset_reconnect_sequence {
	my ($this) = @_;
	$this->{_last_retry} = 0;
	$this->{_next_retry} = $this->{RETRY};
}

# Reconnects to the server after a loss of connection
# When client disconnected from server it will automatically try to reconnect using 
# fibonacci sequence to get interval between reconnect attempts which value grows exponentially. (why not ?)
sub _reconnect {
	my ($this) = @_;
	my $retry_after = $this->{_next_retry} > $this->{MAX_RETRY} ? $this->{MAX_RETRY} : $this->{_next_retry};
	$retry_after = int($retry_after) if $retry_after > 3;
	$this->_debug( "INFO : Centrifugo::Client : will reconnect after $retry_after s." );
	$this->{reconnect_handler} = AnyEvent->timer(
		after => $retry_after,
		cb => sub {
			$this->{_next_retry} += $this->{_last_retry};
			$this->{_last_retry} = $retry_after;
			$this->_connect();
		}
	);
}

# Creates the timer to send periodic ping
sub _init_keep_alive_timer {
	my ($this) = @_;
	$this->{_alive_handler} = AnyEvent->timer(
		after => $this->{REFRESH},
		interval => $this->{REFRESH},
		cb => sub {
			my $late = time() - $this->{_last_alive_message};
			if ($late > $this->{MAX_ALIVE}) {
				$this->_debug( "INFO : Sending ping (${late}s without message)" );
				$this->ping();
			}
		}
	);
}

=head1 FUNCTION publish - allows clients directly publish messages into channel (use with caution. Client->Server communication is NOT the aim of Centrifugo)

    $client->publish( channel=>$channel, data=>$data, [uid => $uid] );

$data must be a HASHREF to a structure (which will be encoded to JSON), for example :

    $client->public ( channel => "public", 
		data => {
			nick => "Anonymous",
			text => "My message",
	    } );

or even :

    $client->public ( channel => "public", data => { } ); # Sends an empty message to the "public" channel

This function returns the UID used to send the command to the server. (a random string if none is provided)
=cut

sub publish {
	my ($this, %PARAMS) = @_;
	croak("Missing channel in Centrifugo::Client->publish(...)") unless $PARAMS{channel};
	croak("Missing data in Centrifugo::Client->publish(...)") unless $PARAMS{data};
	my $uid = $PARAMS{'uid'} || _generate_random_id();
	delete $PARAMS{'uid'};
	$PARAMS{channel}=~s/&.*/'&' . $this->client_id()/e; # Client channel boundary
	$this->_send_message({
		UID => $uid,
		method => 'publish',
		params => \%PARAMS
	});
	return $uid;
}

=head1 FUNCTION disconnect

$client->disconnect();

=cut

sub disconnect {
	my ($this) = @_;
	$this->{WSHANDLE}->close() if $this->{WSHANDLE};	
	my $sub = $this->{ON}->{'disconnect'};
	$sub->() if $sub;
}

=head1 FUNCTION subscribe - allows to subscribe on channel after client successfully connected.

$client->subscribe( channel => $channel, [ uid => $uid ,] );

If the channel is private (starts with a '$'), then a request to $this->{AUTH_URL} is done automatically to get the channel key.

If channel contains a '&', then the function adds the client_id behind the client channel boundary. (even after a reconnect)

This function returns the UIDs used to send the command to the server. (a random string if none is provided)

=cut

sub subscribe {
	my ($this, %PARAMS) = @_;
	my $channel = $PARAMS{channel};
	$channel=~s/&.*/&/; # Client channel boundary
	$this->_debug( "DEBUG: call to subscribe on '$channel'");
	next if $this->{_subscribed_channels}->{ $channel };
	next if $this->{_pending_subscriptions}->{ $channel };

	# If the client is not connected, then delay the subscribing
	unless ($this->client_id()) {
		my $error = "Can't subscribe to channel '$channel' yet : Client is not connected (will try again when connected)";
		$this->_debug( "WARN : Centrifugo::Client : $error" );
		$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
		# Register the channel so that we can subscribe when the client is connected
		$this->{_channels}->{ $channel } = { status => JSON::false };
		return undef;
	}
	$this->{_pending_subscriptions}->{ $channel } = 1; # Don't subscribe again
	
	$this->_debug( "INFO : Centrifugo::Client : Subscribing to $channel" );

	my $SUBREQ = {
		channel => $channel
	};
	
	# Direct subscribe of non-private channels
	return _channel_command($this,'subscribe',%$SUBREQ) unless $channel=~/^\$/; # Private channels starts with $
	
	# If the channel is private, then an API-call to /centrifuge/auth/ must be done
	$SUBREQ->{ client } = $this->client_id();
	
	# Request a channel key
	my $data = encode_json {
		client => $this->client_id(),
		channels => [ $channel ]
	};
	my $URL = $this->{AUTH_URL};
	http_post $URL, $data,
		headers => {
			contentType => "application/json"
		},
		sub {
		  my ($data, $headers) = @_;
		  unless ($headers->{Status}==200) {
		    # Can't access to URL (TODO : should we retry for this ?)
			my $error = "Can't subscribe to channel '$channel' : Couldn't connect to $URL : Status=".$headers->{Status};
			$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
			return;
		  }
		  my $result = decode_json $data;
		  my $key = $result->{$channel}->{sign};
		  $SUBREQ->{sign} = $key;
		  # The request is now complete : {channel: "...", client:"...", sign:"..."}
		  return _channel_command($this,'subscribe',%$SUBREQ);
	   };
}

sub _channel_command {
	my ($this,$command,%PARAMS) = @_;
	$PARAMS{channel} =~s /&.*/'&' . $this->client_id()/e;  # Client channel boundary
	my $uid = $PARAMS{'uid'} || _generate_random_id();
	my $MSG = {
		UID => $uid ,
		method => $command,
		params => \%PARAMS
	};
	$this->_send_message($MSG);
	return $uid;
}

=head1 FUNCTION unsubscribe - allows to unsubscribe from channel.

$client->unsubscribe( channel => $channel, [ uid => $uid ] );

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub unsubscribe {
	my ($this, %PARAMS) = @_;
	return _channel_command($this,'unsubscribe',%PARAMS);
}

=head1 FUNCTION presence - allows to ask server for channel presence information.

$client->presence( channel => $channel, [ uid => $uid ] );

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub presence {
	my ($this, %PARAMS) = @_;
	return _channel_command($this,'presence',%PARAMS);
}

=head1 FUNCTION history - allows to ask server for channel presence information.

$client->history( channel => $channel, [ uid => $uid ] );

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub history {
	my ($this, %PARAMS) = @_;
	return _channel_command($this,'history',%PARAMS);
}

=head1 FUNCTION ping - allows to send ping command to server, server will answer this command with ping response.

$client->ping( [ uid => $uid ] );

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub ping {
	my ($this,%PARAMS) = @_;
	my $uid = $PARAMS{'uid'} || _generate_random_id();
	my $MSG = {
		UID => $uid ,
		method => 'ping'
	};
	$this->_send_message($MSG);
	return $uid;
}

=head1 FUNCTION on - Register a callback for the given event.

Known events are 'message', 'connect', 'disconnect', 'subscribe', 'unsubscribe', 'publish', 'presence', 'history', 'join', 'leave',
'refresh', 'ping', 'ws_closed', 'ws_error'

$client->on( 'connect', sub { 
   my( $dataRef ) = @_;
   ...
});

(this function retuns $self to allow chains of multiple function calls)

Note : Events that are an answer to the client requests (ie 'connect', 'publish', ...) have an 'uid' which is added into the %data structure.

=cut

sub on {
	my ($this, $method, $sub)=@_;
	$this->{ON}->{$method} = $sub;
	$this;
}

=head1 FUNCTION client_id - return the client_id if it is connected to Centrifugo and the server returned this ID (which is not the case on the demo server).

$client->client_id() 

=cut

sub client_id {
	my ($this)=@_;
	return $this->{CLIENT_ID};
}


=head1 FUNCTION generate_token - return the private token that must be used to connect a client to Centrifugo.

$key = Centrifugo::Client::generate_token($secret, $user, $timestamp [,$info])

INPUT : $secret is the private secret key, only known by the server.

        $user is the user name.
        
        $timestamp is the current timestamp.
        
        $info is a JSON encoded string.

The same function may be used to generate a private channel key :

    $key = generate_token($secret, $client, $channel [,$info])

INPUT : $client is the client_id given when connected to Centrifugo.

        $channel is the name of the channel (should start with a '$' as it is private).

And to sign each request to access to the HTTP API :

    $sign = generate_token($self, $data)

INPUT : $data is a JSON string with your API commands

=cut

sub generate_token {
	my ($secret, @infos)=@_;
	my $info = join'', @infos;
	# TODO : faire mieux, mais il suffit de passer un objet JSON
	$info = '{"test":"ok"}';
	use Crypt::JWT qw(encode_jwt);
	return encode_jwt(payload=>$info, alg=>'HS256', key=>$secret);
}

##### (kinda)-private functions

sub _send_message {
	my ($this,$MSG)=@_;
	# Use and increment the ID
	my $id = $MSG->{id} = $this->{_id}++;
	# Save the request
	$this->{_requests}->{ $id } = $MSG;
	$MSG = encode_json $MSG;
	$this->_debug_ws("INFO : WebSocket : Send > $MSG");
	$this->{WSHANDLE}->send($MSG);
}

sub _debug {
	my ($this,$MSG)=@_;
	my $cr=$\;$\="\n";
	print STDERR $MSG if $this->{DEBUG};
	$\=$cr;
}

sub _debug_ws {
	my ($this,$MSG)=@_;
	my $cr=$\;$\="\n";
	print STDERR $MSG if $this->{DEBUG_WS};
	$\=$cr;
}


# Generates a random Id for commands
sub _generate_random_id {
	my @c = ('a'..'z','A'..'Z',0..9);
	return join '', @c[ map{ rand @c } 1 .. 12 ];
}
1;
