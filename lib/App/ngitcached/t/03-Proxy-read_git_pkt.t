use strict;
use warnings;

use Test::More;
use Test::Exception;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_read_git_pkt
{
    my ($r, $w) = ae_handle_pipe( );

    # basic success
    {
        $w->push_write( '00080123' );
        is( read_git_pkt( $r ), '0123' );
    }

    # maximum possible size
    {
        $w->push_write( 'ffff' . ('1' x 65531) );
        is( read_git_pkt( $r ), ('1' x 65531) );
    }

    # corrupt length header
    {
        $w->push_write( 'helo' );
        throws_ok { read_git_pkt( $r ) } qr{\bexpected a hex string\b};
    }

    # other corrupt length header (length of 1 .. 3 is impossible)
    {
        $w->push_write( '0001' );
        throws_ok { read_git_pkt( $r ) } qr{\bcorrupt\b};
    }

    # timeout
    {
        $w->push_write( '000' );
        throws_ok { read_git_pkt( {in=>$r,timeout=>1} ) } qr{\btimed out\b};
    }

    # flush pkt
    {
        $w->push_write( '0' );  # note: 000 still in buffer from above
        ok( !read_git_pkt( $r ) );
    }
}

test_read_git_pkt();
done_testing();

