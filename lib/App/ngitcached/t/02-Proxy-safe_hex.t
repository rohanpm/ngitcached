use strict;
use warnings;

use Test::More;
use Test::Exception;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_safe_hex
{
    is( safe_hex( '0' ), 0 );
    is( safe_hex( '1' ), 1 );
    is( safe_hex( 'f' ), 15 );
    is( safe_hex( '10' ), 16 );
    is( safe_hex( '0x0' ), 0 );
    is( safe_hex( '0x1' ), 1 );
    is( safe_hex( '0xf' ), 15 );
    is( safe_hex( '0x10' ), 16 );

    dies_ok { safe_hex( q{} ) };
    dies_ok { safe_hex( q{q} ) };
    dies_ok { safe_hex( q{x} ) };
}

test_safe_hex();
done_testing();

