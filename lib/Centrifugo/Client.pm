package Centrifugo::Client;

our $VERSION = "1.01";

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw();

use Carp qw( croak );
use AnyEvent::WebSocket::Client 0.12;
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
	   debug => 'true',           # if true, some informations are written on STDERR
	   ws_params => {             # These parameters are passed to AnyEvent::WebSocket::Client->new(...)
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
	$this->{WEBSOCKET} = AnyEvent::WebSocket::Client -> new( %{$params{ws_params}} );
	return $this;
}

=head1 FUNCTION connect

$client->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN );

=cut

sub connect {
	my ($this,%PARAMS) = @_;
	croak("Undefined user in Centrifugo::Client->connect(...)") if ! $PARAMS{user};
	croak("Undefined timestamp in Centrifugo::Client->connect(...)") if ! $PARAMS{timestamp};
	croak("Undefined token in Centrifugo::Client->connect(...)") if ! $PARAMS{token};
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
		
		# Sends a CONNECT message to Centrifugo
		my $CONNECT=encode_json {
			method => 'connect',
			params => \%PARAMS
		};
		
		print STDERR "Centrifugo::Client : WS > $CONNECT\n" if $this->{DEBUG};
		$this->{WSHANDLE}->on(each_message => sub {
			my($loop, $message) = @_;
			print STDERR "Centrifugo::Client : WS < $message->{body}\n" if $this->{DEBUG};
			my $body = decode_json($message->{body});
			if (ref($body) eq 'HASH') {
				$body = [ $body ];
			}
			foreach my $info (@$body) {
				my $method = $info->{method};
				if ($method eq 'connect') {
					# on Connect, the client_id must be read
					if ($info->{body} && ref($body) eq 'HASH' && $info->{body}->{client}) {
						$this->{CLIENT_ID} = $info->{body}->{client};
						print STDERR "Centrifugo::Client : CLIENT_ID=$this->{CLIENT_ID}\n" if $this->{DEBUG};
					}
				}
				my $sub = $this->{ON}->{$method};
				if ($sub) {
					$sub->( $info->{body} );
				}
			}
		});

		unless ($^O=~/Win/i) {
			# This event seems to be unrecognized on Windows (?)
			$this->{WSHANDLE}->on(parse_error => sub {
				my($loop, $error) = @_;
				warn "Error in Centrifugo::Client : $error";
				$this->{ON}->{'error'}->($error) if $this->{ON}->{'error'};
			});
		}

		# handle a closed connection...
		$this->{WSHANDLE}->on(finish => sub {
			my($loop) = @_;
			print STDERR "Centrifugo::Client : Connection closed\n" if $this->{DEBUG};
			$this->{ON}->{'ws_closed'}->() if $this->{ON}->{'ws_closed'};
			undef $this->{WSHANDLE};
			undef $this->{CLIENT_ID};
		});

		$this->{WSHANDLE}->send($CONNECT);

	});
	$this;
}

=head1 FUNCTION publish

    $client->publish( $channel, $data );

$data must be a HASHREF to a structure (which will be encoded to JSON), for example :

    $client->public ( "public", {
	    nick => "Anonymous",
	    text => "My message",
	    } );

or even :

    $client->public ( "public", { } ); # Sends an empty message to the "public" channel

=cut

sub publish {
	my ($this, $channel, $data) = @_;
	my $PUBLISH = encode_json {
		UID => 'anyId',
		method => 'publish',
		params => {
			channel => $channel,
			data => $data
		}
	};
	print STDERR "Centrifugo::Client : WS > $PUBLISH\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send( $PUBLISH );
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

=head1 FUNCTION subscribe

$client->subscribe( $channel );

=cut

sub subscribe {
	my ($this, $channel) = @_;
	my $SUBSCRIBE = encode_json {
		UID => 'anyId',
		method => 'subscribe',
		params => { channel => $channel }
	};
	print STDERR "Centrifugo::Client : WS > $SUBSCRIBE\n" if $this->{DEBUG};
	$this->{WSHANDLE}->send($SUBSCRIBE);
}

=head1 FUNCTION on

$client->on( 'connect', sub { 
   my(%data) = @_;
   ...
});

Known events are 'message', 'connect', 'disconnect', 'subscribe', 'unsubscribe', 'publish', 'presence', 'history', 'join', 'leave',
'refresh', 'ping', 'ws_closed', 'ws_error'

=cut

sub on {
	my ($this, $method, $sub)=@_;
	$this->{ON}->{$method} = $sub;
	$this;
}

=head1 FUNCTION client_id

$client->client_id() return the client_id if it is connected to Centrifugo and the server returned this ID (which is not the case on the demo server).

=cut

sub client_id {
	my ($this)=@_;
	$this->{CLIENT_ID};
}

1;
