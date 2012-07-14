use strict;
use warnings;

use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_pump
{
    # basic success
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe1' );
        my ($r2, $w2) = ae_handle_pipe( 'pipe2' );

        my $cv = pump( $r1, $w2 );
        $w1->push_write( "hi there\n" );

        my $line = bread( $r2, 'line' );
        is( $line, 'hi there' );

        # although data was sent, we didn't shutdown,
        # so the cv should not be ready
        ok( !$cv->ready() );

        # after shutdown, recv() should work
        bshutdown( $w1 );
        $cv->recv();
    }

    # basic error
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe1' );
        my ($r2, $w2) = ae_handle_pipe( 'pipe2' );

        my $cv = pump( $r1, $w2 );
        $w1->push_write( "hi there\n" );

        my $line = bread( $r2, 'line' );
        is( $line, 'hi there' );

        bshutdown( $r2 );
        $w1->push_write( "hi again\n" );
        throws_ok { $cv->recv() } qr{\bpipe2\b.*\bBroken pipe\b};
    }
}

test_pump();
done_testing();

