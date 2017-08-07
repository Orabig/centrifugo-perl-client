use strict;
use warnings;
use 5.010;

use JSON qw!encode_json!;

my $CENTRIFUGO_DEMO = 'centrifugo.herokuapp.com';
my $CHANNEL = 'Perl-Module-Test'; #  $CHANNEL = 'public';
my $DEBUG = 0;

use Test::More tests => 3; # Connect, subscribe, send/receive random message

use Centrifugo::Client;

sub getRandomId() {
	my $id = hmac_sha256_hex(rand());
	$id=~s/(.{5}).*/$1/;
	$id;
}

SKIP: {
	eval 'use Digest::SHA qw( hmac_sha256_hex )';
	skip "Digest::SHA not available", 1 if $@;
	
	our $condvar = AnyEvent->condvar;

	# This part is aiming to get a valid TOKEN for Centrifugo_demo site.
	# On real application, this step should ALWAYS be done on server side
	my $USER      = 'perl-module-test';
	my $TIMESTAMP = time();
	my $SECRET = "secret";
	
	my $message = "Secret message : ".getRandomId();
	
	my $TOKEN = hmac_sha256_hex( $USER, $TIMESTAMP, $SECRET );
	
	my $cclient = Centrifugo::Client->new("ws://$CENTRIFUGO_DEMO/connection/websocket", debug => $DEBUG );

	$cclient-> on('connect', sub{
		my ($infoRef)=@_;
		ok 1, "Connected to $CHANNEL";
		# Sends a message on Channel Perl-Module-Test
		my $uid=$cclient-> subscribe( channel=>$CHANNEL );
	})-> on('subscribe', sub{
		my ($infoRef)=@_;
		ok 1, "Subscribed to $CHANNEL";
		
		# Sends a message on Channel Perl-Module-Test
		diag "Send message : $message";
		$cclient-> publish( channel=>$CHANNEL, data => { message=>$message } );
	})-> on('message', sub{
		my ($infoRef)=@_;

		my $rcv = $infoRef->{data}->{message};
		if ($rcv eq $message ) {
			ok(1, "Message received");
		}
		$condvar->send;
	})-> on('disconnect', sub{
		my ($infoRef)=@_;
		diag "Received : Disconnected : ".$infoRef;
		$condvar->send;
	})-> on('error', sub{
		my ($error)=@_;
		$condvar->send;
	})-> on('ws_closed', sub{
		my ($reason)=@_;
		diag "Received : Websocket connection closed : $reason";
		$condvar->send;
	})->connect(
		user => $USER,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	);
	
	$condvar->recv;
	
}
	