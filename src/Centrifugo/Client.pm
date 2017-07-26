package Centrifugo::Client;

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

 $cclient->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	) -> on('connect', sub{
		my ($infoRef)=@_;
		print "Connected to Centrifugo version ".$infoRef->{version};
		
		# When connected, client_id() is defined, so we can subscribe to our private channel
		$cclient->subscribe( '&'.$cclient->client_id() );
		
	})-> on('message', sub{
		my ($infoRef)=@_;
		print "MESSAGE: ".encode_json $infoRef->{data};

	});

 # Now start the event loop to keep the program alive
 AnyEvent->condvar->recv;
	
=head1 DESCRIPTION

This library allows to communicate with Centrifugo through a websocket.

=cut

use strict;
use warnings;


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
	croak("Undefined user") if ! $PARAMS{user};
	croak("Undefined timestamp") if ! $PARAMS{timestamp};
	croak("Undefined token") if ! $PARAMS{token};
	$this->{WEBSOCKET}->connect( $this->{WS_URL} )->cb(sub {
		# Connects to Websocket
		$this->{WSHANDLE} = eval { shift->recv };
		if($@) {
			# handle error...
			warn $@;
			return;
		}
		
		$PARAMS{timestamp}="$PARAMS{timestamp}"; # This MUST be a string		
		# Sends a CONNECT message to Centrifugo
		my $CONNECT=encode_json {
			UID => 'someId',
			method => 'connect',
			params => \%PARAMS
		};
		print STDERR "Centrifugo::Client : WS > $CONNECT\n" if $this->{DEBUG};
		$this->{WSHANDLE}->send($CONNECT);
		
		$this->{WSHANDLE}->on(each_message => sub {
			my($loop, $message) = @_;
			print STDERR "Centrifugo::Client : WS < $message->{body}\n" if $this->{DEBUG};
			my $body = decode_json($message->{body});
			my $method = $body->{method};
			if ($method eq 'connect') {
				# on Connect, the client_id must be read
				$this->{CLIENT_ID} = $body->{body}->{client};
				print STDERR "Centrifugo::Client : CLIENT_ID=$this->{CLIENT_ID}\n" if $this->{DEBUG};
			}
			my $sub = $this->{ON}->{$method};
			if ($sub) {
				$sub->( $body->{body} );
			}
		});
		
		$this->{WSHANDLE}->on(parse_error => sub {
			my($loop, $error) = @_;
			warn "ERROR in Centrifugo::Client : $error";
		});
		
		# handle a closed connection...
		$this->{WSHANDLE}->on(finish => sub {
			my($loop) = @_;
			print STDERR "Centrifugo::Client : Connection closed\n" if $this->{DEBUG};
			undef $this->{WSHANDLE};
			undef $this->{CLIENT_ID};
		});
	});
	$this;
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
'refresh', 'ping'

=cut

sub on {
	my ($this, $method, $sub)=@_;
	$this->{ON}->{$method} = $sub;
	$this;
}

=head1 FUNCTION client_id

$client->client_id() return the client_id if it is connected to Centrifugo, or undef.

=cut

sub client_id {
	my ($this)=@_;
	$this->{CLIENT_ID};
}

1;
__DATA__
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

1;