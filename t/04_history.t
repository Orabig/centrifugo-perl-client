use strict;
use warnings;
use 5.010;

use JSON qw!encode_json!;

my $CENTRIFUGO_DEMO = 'centrifugo.herokuapp.com';
my $CHANNEL = 'Perl-Module-Test'; #  $CHANNEL = 'public';
my $DEBUG = 0;

use Test::More tests => 4; # Connect, subscribe, send 2 random messages, check history

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
	my $message2 = "Secret message : ".getRandomId();
	
	my $TOKEN = hmac_sha256_hex( $USER, $TIMESTAMP, $SECRET );
	
	my $cclient = Centrifugo::Client->new("ws://$CENTRIFUGO_DEMO/connection/websocket", debug => $DEBUG );

	$cclient-> on('connect', sub{
		my ($infoRef)=@_;
		ok 1, "Connected to $CHANNEL";
		# Sends a message on Channel Perl-Module-Test
		my $uid=$cclient-> subscribe( channel=>$CHANNEL );
		
		# $condvar->send;
	})-> on('subscribe', sub{
		my ($infoRef)=@_;
		ok 1, "Subscribed to $CHANNEL";
		
		# Sends a message on Channel Perl-Module-Test
		diag "Send message : $message";
		$cclient-> publish( channel=>$CHANNEL, data => { message=>$message } );
		diag "Send message : $message2";
		$cclient-> publish( channel=>$CHANNEL, data => { message=>$message2 } );
		
		$cclient-> history( channel=>$CHANNEL );
		
		# $condvar->send;
	})-> on('history', sub{
		my ($infoRef)=@_;

		my $history = $infoRef->{data};
		foreach my $data (@$history) {
			my $msg = $data->{data}->{message};
			foreach my $ref ($message,$message2) {
				ok('true', "Message $ref found in 'history' result") if $ref eq $msg;
			}
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
		diag "Received : Websocket connection closed";
		$condvar->send;
	})->connect(
		user => $USER,
		timestamp => $TIMESTAMP,
		token => $TOKEN, uid=>"ABBBCCCDDDEEEFFFGGG"
	);
	
	$condvar->recv;
	
}
	