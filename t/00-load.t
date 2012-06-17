#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'App::ngitcached' ) || print "Bail out!\n";
}

diag( "Testing App::ngitcached $App::ngitcached::VERSION, Perl $], $^X" );
