use strict;
use warnings;
use 5.010;

use Test::More tests => 1;

use Centrifugo::Client;

SKIP: {
	eval 'use LWP::UserAgent';
	skip "LWP::UserAgent not available", 1 if $@;
	eval 'use LWP::Protocol::https';
	skip "LWP::Protocol::https not available", 1 if $@;
	eval 'use HTTP::Request::Common qw{ POST }';
	skip "HTTP::Request::Common not available", 1 if $@;

	my $CENTRIFUGO_DEMO = 'centrifugo.herokuapp.com';

	# This part is aiming to get a valid TOKEN for Centrifugo_demo site.
	my $USER    = 'demo';
	my $password= 'demo';
	my $ua      = LWP::UserAgent->new();
	my $request = POST( "https://$CENTRIFUGO_DEMO/auth/", [ 'password' => $password ] );
	my $content = $ua->request($request)->as_string();
	
	skip "TOKEN not provided by $CENTRIFUGO_DEMO" unless $content=~/"token":"([^"]+)"/;
	my $TOKEN = $1;
	
	my $cclient = Centrifugo::Client->new("wss://$CENTRIFUGO_DEMO/socket");

	$cclient->connect(
		user => $USER,
		timestamp => time(),
		token => $TOKEN
	)-> on('connect', sub{
		my ($infoRef)=@_;
		print "Connected to Centrifugo version ".$infoRef->{version};
	})-> on('error', sub{
		my ($error)=@_;
		print "Error".$error;
	});
	
	# AnyEvent->condvar->recv;
	
	SKIP: {
		skip "Sorry, no test for now. Couldn't figure out how to connect on official Centrifugo Demo server", 1;
		ok( 0==1 );
	}
}
	