use strict;
use warnings;
use 5.010;

use JSON qw!encode_json!;

my $CENTRIFUGO_DEMO = 'centrifugo.herokuapp.com';
my $CHANNEL = 'Perl-Module-Test'; #  $CHANNEL = 'public';
my $DEBUG = 0;

use Test::More tests => 3; # Connect, ping/pong

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
	
	my $TOKEN = hmac_sha256_hex( $USER, $TIMESTAMP, $SECRET );
	
	my $cclient = Centrifugo::Client->new("ws://$CENTRIFUGO_DEMO/connection/websocket", debug => $DEBUG );
	
	my $uid = getRandomId();

	$cclient-> on('connect', sub{
		my ($infoRef)=@_;
		ok 1, "Connected to $CHANNEL";
		diag "Send ping : (uid=$uid)";
		$uid=$cclient-> ping( uid=>$uid );
	})-> on('ping', sub{
		my ($infoRef)=@_;
		ok 1, "Ping received";
		ok $infoRef->{uid} eq $uid, "Same ping UID returned";
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
	