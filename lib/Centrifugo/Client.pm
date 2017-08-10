package Centrifugo::Client;

our $VERSION = "1.03";

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
	$this->{DEBUG} = $params{debug} && uc($params{debug})ne'FALSE';
	$this->{AUTH_URL} = $params{authEndpoint} || "/centrifuge/auth/";
	$this->{WEBSOCKET} = AnyEvent::WebSocket::Client -> new( %{$params{ws_params}} );
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

(this function retuns $self to allow chains of multiple function calls)
		
It is possible to provide a UID for this command, but if you don't, a random one will be generated for you, but cannot be retrieved afterward.

=cut

sub connect {
	my ($this,%PARAMS) = @_;
	croak("Missing user in Centrifugo::Client->connect(...)") if ! $PARAMS{user};
	croak("Missing timestamp in Centrifugo::Client->connect(...)") if ! $PARAMS{timestamp};
	croak("Missing token in Centrifugo::Client->connect(...)") if ! $PARAMS{token};
	$this->{WEBSOCKET}->connect( $this->{WS_URL} )->cb(sub {
		# Connects to Websocket
		$this->{WSHANDLE} = eval { shift->recv };
		if($@) {
			# handle error...
			warn "Error in Centrifugo::Client : $@";
			$this->{ON}->{'error'}->($@) if $this->{ON}->{'error'};
			return;
		}
		
		# Fix parameters sent to Centrifugo
		$PARAMS{timestamp}="$PARAMS{timestamp}" if $PARAMS{timestamp}; # This MUST be a string
		
		my $uid=$PARAMS{uid} || _generate_random_id();
		delete $PARAMS{uid};
		# Sends a CONNECT message to Centrifugo
		my $CONNECT=encode_json {
			UID => $uid,
			method => 'connect',
			params => \%PARAMS
		};
		
		print STDERR "Centrifugo::Client : WS > $CONNECT\n" if $this->{DEBUG};
		$this->{WSHANDLE}->on(each_message => sub {
			my($loop, $message) = @_;
			print STDERR "Centrifugo::Client : WS < $message->{body}\n" if $this->{DEBUG};
			my $fullbody = decode_json($message->{body});
			# Handle a body containing {response}
			if (ref($fullbody) eq 'HASH') {
				$fullbody = [ $fullbody ];
			}
			# Handle a body containing [{response},{response}...]
			foreach my $info (@$fullbody) {
				my $uid = $info->{uid};
				my $method = $info->{method};
				my $error = $info->{error};
				my $body = $info->{body}; # Not the same 'body' as above
				if ($method eq 'connect') {
					# on Connect, the client_id must be read (if available)
					if ($body && ref($body) eq 'HASH' && $body->{client}) {
						$this->{CLIENT_ID} = $body->{client};
						print STDERR "Centrifugo::Client : CLIENT_ID=".$this->{CLIENT_ID}."\n" if $this->{DEBUG};
					}
				}
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
		});

		unless ($^O=~/Win/i) {
			# This event seems to be unrecognized on Windows (?)
			$this->{WSHANDLE}->on(parse_error => sub {
				my($cnx, $error) = @_;
				warn "Error in Centrifugo::Client : $error";
				$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
			});
		}

		# handle a closed connection...
		$this->{WSHANDLE}->on(finish => sub {
			my($cnx) = @_;
			my $reason = $cnx->close_reason();
			do {
				$reason = (decode_json $reason)->{reason};
			};
			
			print STDERR "Centrifugo::Client : Connection closed (reason=$reason)\n" if $this->{DEBUG};
			$this->{ON}->{'ws_closed'}->($reason) if $this->{ON}->{'ws_closed'};
			undef $this->{WSHANDLE};
			undef $this->{CLIENT_ID};
		});

		$this->{WSHANDLE}->send($CONNECT);

	});
	$this;
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
	my $PUBLISH = encode_json {
		UID => $uid,
		method => 'publish',
		params => \%PARAMS
	};
	print STDERR "Centrifugo::Client : WS > $PUBLISH\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send( $PUBLISH );
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

$client->subscribe( channel => $channel, [ client => $clientId  ,] [ uid => $uid ,] );

If the channel is private (starts with a '$'), then a request to $this->{AUTH_URL} is done automatically to get the channel key. In that case, the 'client' parameter is mandatory.

This function returns the UID used to send the command to the server. (a random string if none is provided)

=cut

sub subscribe {
	my ($this, %PARAMS) = @_;
	my $channel = $PARAMS{channel};
	return _channel_command($this,'subscribe',%PARAMS) unless $channel=~/^\$/;
	# If the channel is private, then an API-call to /centrifuge/auth/ must be done
	croak "'client' parameter is mandatory to subscribe to private channels in Centrifugo::Client->subscribe(...)" unless $PARAMS{client};

	# Request a channel key
	my $data = encode_json {
		client => $PARAMS{client},
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
		  # The request is now complete : {channel:"...", client:"...", sign:"..."}
		  return _channel_command($this,'subscribe',%PARAMS);
	   };
}

sub _channel_command {
	my ($this,$command,%PARAMS) = @_;
#	my $channel = $PARAMS{'channel'};
#	croak("Missing channel in Centrifugo::Client->$command(...)") unless $PARAMS{'channel'};
	my $uid = $PARAMS{'uid'} || _generate_random_id();
	my $MSG = encode_json {
		UID => $uid ,
		method => $command,
		params => \%PARAMS
	};
	print STDERR "Centrifugo::Client : WS > $MSG\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send($MSG);
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
	my $MSG = encode_json {
		UID => $uid ,
		method => 'ping'
	};
	print STDERR "Centrifugo::Client : WS > $MSG\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send($MSG);
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

# Generates a random Id for commands
sub _generate_random_id {
	my @c = ('a'..'z','A'..'Z',0..9);
	return join '', @c[ map{ rand @c } 1 .. 12 ];
}
1;
