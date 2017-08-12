package Centrifugo::Client;

our $VERSION = "1.04";

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(generate_token);

use Carp qw( croak );
use AnyEvent::WebSocket::Client 0.40; # Version needed for reason when close. See https://github.com/plicease/AnyEvent-WebSocket-Client/issues/30
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
		
		# When connected, client_id() is defined, so we can subscribe to our private channel
		$cclient->subscribe( '&'.$cclient->client_id() );
		
	}) -> on('message', sub{
		my ($infoRef)=@_;
		print "MESSAGE: ".encode_json $infoRef->{data};

	}) -> connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	);

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
	$this->{AUTH_URL} = delete $params{authEndpoint} || "/centrifuge/auth/";
	$this->{WEBSOCKET} = AnyEvent::WebSocket::Client -> new( %{$params{ws_params}} ); delete $params{ws_params};
	$this->{MAX_ALIVE} = delete $params{max_alive_period} || 0;
	$this->{REFRESH} = delete $params{refresh_period} || 10;
	$this->{RETRY} = delete $params{retry} || 1;
	$this->{MAX_RETRY} = delete $params{max_retry} || 30;
	$this->{RESUBSCRIBE} = $params{resubscribe} || $params{resubscribe}!~/^(0|false|no)$/i; delete $params{resubscribe};
	$this->{RECOVER} = $params{recover} && $params{recover}!~/^(0|false|no)$/i; delete $params{recover};
	$this->{_first_connection} = 'TRUE'; # This indicator is useful for recover algorithm
	croak "Centrifugo::Client : Unknown parameter : ".join',',keys %params if %params;
	print "resub=$this->{RESUBSCRIBE}";
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
	$this->{WEBSOCKET}->connect( $this->{WS_URL} )->cb(sub {
		$this->{WSHANDLE} = eval { shift->recv };
		if ($@) {
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
	print STDERR "Centrifugo::Client : WebSocket connected to $this->{WS_URL}\n" if $this->{DEBUG};
	
	# define the callbacks
	$this->{WSHANDLE}->on(each_message => sub { $this->_on_message($_[1]) });
	$this->{WSHANDLE}->on(finish => sub { $this->_on_close(($_[0])->close_reason()) });
	$this->{WSHANDLE}->on(parse_error => sub {
		my($cnx, $error) = @_;
		print STDERR "Error in Centrifugo::Client : $error\n" if $this->{DEBUG};
		$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
	});
	
	# Then, connects to Centrifugo
	$this->_send_message( {
		method => 'connect',
		UID => $this->{_cnx_uid},
		params => $this->{_cnx_params}
	} );
}

# This function is called when client is connected to Centrifugo
sub _on_connect {
	my ($this, $body) = @_;
	print STDERR "Centrifugo::Client : Connected to Centrifugo : ".encode_json $body if $this->{DEBUG};	
	# on Connect, the client_id must be read (if available)
	if ($body && ref($body) eq 'HASH' && $body->{client}) {
		$this->{CLIENT_ID} = $body->{client};
		print STDERR "Centrifugo::Client : CLIENT_ID=".$this->{CLIENT_ID}."\n" if $this->{DEBUG};
	}
	$this->_init_keep_alive_timer() if $this->{MAX_ALIVE};
	$this->_reset_reconnect_sequence();
	$this->_resubscribe() if $this->{RESUBSCRIBE};
	delete $this->{_first_connection}; # Next connection should use resubscribe and recover is any
}

# This function is called when client is connected to Centrifugo
sub _on_subscribe {
	my ($this, $body) = @_;
	my $channel = $body->{channel};
	print STDERR "Centrifugo::Client : Subscribed to $channel : ".encode_json $body if $this->{DEBUG};
	# Keeps track of channels
	$this->{channels}->{ $channel } = $body;
}

# This function is called when client is connected to Centrifugo
sub _on_unsubscribe {
	my ($this, $body) = @_;
	my $channel = $body->{channel};
	print STDERR "Centrifugo::Client : Unsubscribed from $body->{channel} : ".encode_json $body if $this->{DEBUG};
	# Keeps track of channels
	delete $this->{channels}->{ $channel };
}

# This function automatically reconnects to channels
sub _resubscribe {
	my ($this) = @_;
	foreach my $channel (keys %{$this->{channels}}) {
		print STDERR "Centrifugo::Client : Resubscribe to $channel" if $this->{DEBUG};
		$this->subscribe( 
			channel => $channel,
			client => $this->client_id()
		);
	}
}

# This function is called when the connection with server is lost
sub _on_close {
	my ($this, $message) = @_;
	print STDERR "Centrifugo::Client : Connection closed (reason=$message)\n" if $this->{DEBUG};
	$this->{ON}->{'ws_closed'}->($message) if $this->{ON}->{'ws_closed'};
	undef $this->{_alive_handler};
	undef $this->{WSHANDLE};
	undef $this->{CLIENT_ID};
	$this->_reconnect();
}

# This function is called if an errors occurs with the server
sub _on_error {
	my ($this, @infos) = @_;
	warn "Error in Centrifugo::Client : @infos";
	$this->{ON}->{'error'}->(@infos) if $this->{ON}->{'error'};
}

# This function is called once for each message received from Centrifugo
sub _on_message {
	my ($this, $message) = @_;
	print STDERR "Centrifugo::Client : R< WS : $message->{body}\n" if $this->{DEBUG};
	$this->{_last_alive_message} = time();
	my $fullbody = decode_json($message->{body}); # The body of websocket message
	# Handle a body containing {response} : converts into a singleton
	if (ref($fullbody) eq 'HASH') {
		$fullbody = [ $fullbody ];
	}
	# Handle the body which is now an array of response
	foreach my $info (@$fullbody) {
		my $uid = $info->{uid};
		my $method = $info->{method};
		my $body = $info->{body}; # The body of Centrifugo message
		$this->_on_connect( $body ) if $method eq 'connect';
		$this->_on_subscribe( $body ) if $method eq 'subscribe';
		$this->_on_unsubscribe( $body ) if $method eq 'unsubscribe';

		# Call the callback of the method
		my $sub = $this->{ON}->{$method};
		if ($sub) {
			# Add UID into body if available
			if ($uid) {
				$body->{uid}=$uid;
			}
			$sub->( $body );
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
	print STDERR "Centrifugo::Client : will reconnect after $retry_after s.\n" if $this->{DEBUG};
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
				print STDERR "Sending ping (${late}s without message)\n" if $this->{DEBUG};
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

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub subscribe {
	my ($this, %PARAMS) = @_;
	my $channel = $PARAMS{channel}; # TODO : Handle list of channels (watch out for return values)
	return _channel_command($this,'subscribe',%PARAMS) unless $channel=~/^\$/;
	# If the channel is private, then an API-call to /centrifuge/auth/ must be done
	croak "Can't subscribe to private channels : Client is not connected in Centrifugo::Client->subscribe(...)" unless $this->client_id();

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
		  warn "Couldn't connect to $URL : Status=".$headers->{Status} and return unless $headers->{Status}==200;
		  my $result = decode_json $data;
		  my $key = $result->{$channel}->{sign};
		  $PARAMS{sign} = $key;
		  # The request is now complete : {channels: ["...",...], client:"...", sign:"..."}
		  return _channel_command($this,'subscribe',%PARAMS);
	   };
}

sub _channel_command {
	my ($this,$command,%PARAMS) = @_;
#	my $channel = $PARAMS{'channel'};
#	croak("Missing channel in Centrifugo::Client->$command(...)") unless $PARAMS{'channel'};
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
	use Digest::SHA qw( hmac_sha256_hex );
	return hmac_sha256_hex( $info, $secret );
}

##### (kinda)-private functions

sub _send_message {
	my ($this,$MSG)=@_;
	$MSG = encode_json $MSG;
	print STDERR "Centrifugo::Client : S> WebSocket : $MSG\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send($MSG);
	
}


# Generates a random Id for commands
sub _generate_random_id {
	my @c = ('a'..'z','A'..'Z',0..9);
	return join '', @c[ map{ rand @c } 1 .. 12 ];
}
1;
