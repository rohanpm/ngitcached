use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_printable
{
    is( printable( 'hi there' ), 'hi there' );

    is( printable( "hi\x02there\x88" ), "hi\\x02there\\x88" );

    is( printable( "hi\r\nthere" ), "hi\\r\\nthere" );

    is(
        printable( 'The quick brown fox jumps over the lazy dog' ),
        'The quick brown fox jumps over the lazy dog',
    );
}

test_printable();
done_testing();

