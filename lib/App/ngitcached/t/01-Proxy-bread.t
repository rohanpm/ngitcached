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
        my ($r, $w) = ae_handle_pipe( 'pipe_success' );
        $w->push_write( "hi there\n" );
        my $line = bread( $r, 'line' );
        is( $line, 'hi there' );
    }

    # timeout (no data)
    {
        my ($r, $w) = ae_handle_pipe( 'pipe_timeout1' );
        throws_ok {
            bread( {in=>$r,timeout=>1}, 'line' );
        } qr{\btimed out\b}, 'times out as expected (no data)';
    }

    # timeout (not enough data)
    {
        my ($r, $w) = ae_handle_pipe( 'pipe_timeout2' );
        $w->push_write( '012345' );
        throws_ok {
            bread( {in=>$r,timeout=>1}, chunk => 10 );
        } qr{\btimed out\b}, 'times out as expected (not enough data)';
    }

    # error in some other handle via generic_handle_error_cb
    {
        my ($r, $w) = ae_handle_pipe( 'pipe_other1' );
        my ($r2, $w2) = ae_handle_pipe( 'pipe_other2' );
        $r2->on_error( generic_handle_error_cb() );
        $r2->push_read( chunk => 2, sub { fail('read chunk') } );
        ok( close( $w2->fh() ) );

        # bread for pipe1 will process events; the error shall
        # be queued until read on pipe2.
        throws_ok {
            bread( {in=>$r,timeout=>1}, 'line' );
        } qr{\bpipe_other2\b.*\bBroken pipe\b}, 'error raised as expected';
    }

    # error (EPIPE)
    {
        my ($r, $w) = ae_handle_pipe( 'pipe_EPIPE' );
        ok( close( $w->fh() ) );
        throws_ok {
            bread( {in=>$r,timeout=>1}, 'line' );
        } qr{\bpipe_EPIPE\b.*\bBroken pipe\b}, 'error raised as expected (remote end closed)';
    }
}

test_bread();
done_testing();

