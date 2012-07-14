use strict;
use warnings;

use Test::More;
use Test::Exception;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub blocking_read
{
    my ($h, @args) = @_;

    $h->unshift_read(
        @args,
        Coro::rouse_cb()
    );

    return Coro::rouse_wait();
}

sub test_write_git_pkt
{
    my ($r, $w) = ae_handle_pipe( );

    # basic success
    {
        write_git_pkt( $w, 'test' );
        my @result = blocking_read( $r, chunk => 8 );
        is( $result[1], '0008test' );
    }

    # write to buffer
    {
        my $buf;
        write_git_pkt( \$buf, 'test2' );
        is( $buf, '0009test2' );
    }

    # flush pkt
    {
        write_git_pkt( $w );
        my @result = blocking_read( $r, chunk => 4 );
        is( $result[1], '0000' );
    }

    # empty string
    {
        write_git_pkt( $w, q{} );
        my @result = blocking_read( $r, chunk => 4 );
        is( $result[1], '0004' );
    }

    # too big
    {
        throws_ok {
            write_git_pkt( $w, ('1' x 100000) );
        } qr{\btoo large\b};
    }
}

test_write_git_pkt();
done_testing();

