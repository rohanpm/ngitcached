use strict;
use warnings;

use AnyEvent;
use Coro::AnyEvent;
use Coro;
use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Coro;

sub test_nrouse
{
    # basic success
    {
        my $cb = nrouse_cb( );
        AE::postpone { $cb->( 'foo', 'bar', 'baz' ) };
        my (@result) = nrouse_wait( );
        is( $result[0], 'foo' );
        is( $result[1], 'bar' );
        is( $result[2], 'baz' );
    }

    # basic die
    {
        my $coro = $Coro::current;
        my $cb = nrouse_cb( );
        AE::postpone { nrouse_die( $coro, 'some error' ) };
        throws_ok {
            nrouse_wait( );
        } qr{\bsome error\b}, 'nrouse_die dies at wait() as expected';
    }

    # multiple cbs
    {
        my @cb = map { nrouse_cb( ) } (1..3);
        AE::postpone {
            $cb[1]->( 'first' );
            $cb[2]->( 'second' );
            $cb[0]->( 'third' );
        };

        # no explicit arg means the last created - $cb[2]
        is( nrouse_wait( ), 'second' );

        is( nrouse_wait( $cb[1] ), 'first' );
        is( nrouse_wait( $cb[0] ), 'third' );

        # waiting again for any of them should return nothing
        for my $i (0..2) {
            ok( !nrouse_wait( $cb[$i] ) );
        }
    }

    # multiple cb and die
    {
        my @cb = map { nrouse_cb( ) } (1..3);
        my $coro = $Coro::current;

        AE::postpone {
            nrouse_die( $coro, 'gosh darn it!' );
        };

        # all of them should die
        foreach my $i (1, 0, 2) {
            throws_ok {
                nrouse_wait( $cb[$i] );
            } qr{gosh darn it};
        }
    }

    # ensure no leaks
    {
        my $last_count = sub {
            scalar keys %App::ngitcached::Coro::LAST_CB_BY_CORO;
        };
        my $count = sub {
            if (my $coro = shift) {
                return scalar @{ $App::ngitcached::Coro::CB_BY_CORO{ $coro } || [] };
            }
            scalar keys %App::ngitcached::Coro::CB_BY_CORO;
        };

        my $init_last_count = $last_count->();
        my $init_count = $count->();
        
        my $coro = async {
            is( $last_count->(), $init_last_count );
            is( $count->() , $init_count );

            my @cb = map { nrouse_cb( ) } (1..3);

            is( $last_count->(), $init_last_count + 1 );
            is( $count->() , $init_count + 1 );
            is( $count->( $Coro::current), 3 );

            undef @cb;

            # note the last cb remains referenced, but all
            # others are eliminated.
            is( $last_count->(), $init_last_count + 1 );
            is( $count->() , $init_count + 1 );
            is( $count->( $Coro::current), 1 );
        };

        $coro->join();

        # after the join, the counts should be as they were before
        # the coro was created
        is( $last_count->(), $init_last_count );
        is( $count->(), $init_count );
    }

    # multiple cb and destruction
    {
        my @cb = map { nrouse_cb( ) } (1..3);
        $cb[0]->( 'first' );
        $cb[1]->( 'second' );
        $cb[2]->( 'third' );

        undef @cb;

        # last created still works, even though we undef'd
        is( nrouse_wait( ), 'third' );
    }

    # array context matches rouse_cb(), rouse_wait()
    {
        my $cb = nrouse_cb( );
        $cb->( 'hello', 'world' );
        my @data = nrouse_wait( $cb );
        is_deeply( \@data, [ 'hello', 'world' ] );
    }

    # scalar context matches rouse_cb(), rouse_wait()
    {
        my $cb = nrouse_cb( );
        $cb->( 'hello', 'world' );
        my $data = nrouse_wait( $cb );
        is( $data, 'world' );
    }
}

test_nrouse();
done_testing();

