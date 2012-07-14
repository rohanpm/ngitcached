use strict;
use warnings;

use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_read_client_have
{
    # basic success
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe1' );

        my $sha_pref = '257cc5642cb1a054f08cc83f2d943e56fd3ebe9';
        write_git_pkt( $w1, "have ${sha_pref}0\n" );
        write_git_pkt( $w1, "have ${sha_pref}1\n" );
        write_git_pkt( $w1, "have ${sha_pref}2\n" );
        write_git_pkt( $w1, "have ${sha_pref}3\n" );
        write_git_pkt( $w1, "have ${sha_pref}4\n" );
        write_git_pkt( $w1, "have ${sha_pref}5\n" );
        write_git_pkt( $w1, "done\n" );
        $w1->push_write( 'some other non-git data' );

        my $data = read_client_have( $r1 );
        is_deeply(
            $data,
            {
                have => {
                    $sha_pref.'0' => 1,
                    $sha_pref.'1' => 1,
                    $sha_pref.'2' => 1,
                    $sha_pref.'3' => 1,
                    $sha_pref.'4' => 1,
                    $sha_pref.'5' => 1,
                },
            }
        );
    }

    # bad data
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe3' );

        write_git_pkt( $w1, "have foo\n" );

        throws_ok {
            read_client_have( $r1 );
        } qr{\bnot a valid 'have'};
    }
}

test_read_client_have();
done_testing();

