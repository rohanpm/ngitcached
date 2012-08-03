use strict;
use warnings;

use Data::Dumper;
use Sub::Override;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_retry
{
    # basic success
    {
        my $i = 0;
        retry { ++$i; };
        is( $i, 1, 'basic success' );
    }

    # retry on death
    {
        my $i = 0;
        retry { 
            ++$i;
            if ($i < 2) {
                die 'some bogus error';
            }
        };
        is( $i, 2, 'success after some retries' );
    }

    # eventually die
    {
        my $i = 0;

        # mock fib terms so the test is reasonably fast
        my $override = Sub::Override->new(
            'Math::Fibonacci::term' => sub { 0 },
        );

        throws_ok {
            retry {
                ++$i;
                die "some bogus error $i";
            };
        } qr{some bogus error 20}, 'eventually dies';
    }
}

test_retry();
done_testing();

