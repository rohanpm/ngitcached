use strict;
use warnings;

use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_bread
{
    # basic success
    {
        my ($r, $w) = ae_handle_pipe( );
        $w->push_write( "hi there\n" );
        my ($h, $line) = bread( $r, 'line' );
        is( $h, $r );
        is( $line, 'hi there' );
    }

    # timeout (no data)
    {
        my ($r, $w) = ae_handle_pipe( );
        throws_ok {
            bread( {in=>$r,timeout=>1}, 'line' );
        } qr{\btimed out\b}, 'times out as expected (no data)';
    }

    # timeout (not enough data)
    {
        my ($r, $w) = ae_handle_pipe( );
        $w->push_write( '012345' );
        throws_ok {
            bread( {in=>$r,timeout=>1}, chunk => 10 );
        } qr{\btimed out\b}, 'times out as expected (not enough data)';

        # verify the data can still be read
        my ($h, $data) = bread( {in=>$r,timeout=>1}, chunk => 6 );
        is( $h, $r );
        is( $data, '012345' );
    }

    # error in some other handle via generic_handle_error_cb
    {
        my ($r, $w) = ae_handle_pipe( 'pipe1' );
        my ($r2, $w2) = ae_handle_pipe( 'pipe2' );
        $r2->on_error( generic_handle_error_cb() );
        $r2->push_read( chunk => 2, sub { fail('read chunk') } );
        ok( close( $w2->fh() ) );

        throws_ok {
            bread( $r, 'line' );
        } qr{\bpipe2\b.*\bBroken pipe\b}, 'error raised as expected (via nrouse_die)';
    }

    # error (EPIPE)
    {
        my ($r, $w) = ae_handle_pipe( 'pipe1' );
        ok( close( $w->fh() ) );
        throws_ok {
            bread( {in=>$r,timeout=>1}, 'line' );
        } qr{\bpipe1\b.*\bBroken pipe\b}, 'error raised as expected (remote end closed)';
    }
}

test_bread();
done_testing();

