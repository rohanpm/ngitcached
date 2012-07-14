use strict;
use warnings;

use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_read_client_want
{
    # basic success
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe1' );

        my $sha_pref = '257cc5642cb1a054f08cc83f2d943e56fd3ebe9';
        write_git_pkt( $w1, "want ${sha_pref}0\n" );
        write_git_pkt( $w1, "want ${sha_pref}1\n" );
        write_git_pkt( $w1, "want ${sha_pref}2\n" );
        write_git_pkt( $w1, "want ${sha_pref}3\n" );
        write_git_pkt( $w1, "want ${sha_pref}4\n" );
        write_git_pkt( $w1, "want ${sha_pref}5\n" );
        write_git_pkt( $w1 );
        $w1->push_write( 'some other non-git data' );

        my $data = read_client_want( $r1 );
        is_deeply(
            $data,
            {
                want => {
                    $sha_pref.'0' => 1,
                    $sha_pref.'1' => 1,
                    $sha_pref.'2' => 1,
                    $sha_pref.'3' => 1,
                    $sha_pref.'4' => 1,
                    $sha_pref.'5' => 1,
                },
                caps => {},
            }
        );
    }

    # with caps
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe2' );

        my $sha_pref = '257cc5642cb1a054f08cc83f2d943e56fd3ebe9';
        write_git_pkt( $w1, "want ${sha_pref}0 cap1 cap2 cap3 cap4\n" );
        write_git_pkt( $w1, "want ${sha_pref}1\n" );
        write_git_pkt( $w1 );
        $w1->push_write( 'some other non-git data' );

        my $data = read_client_want( $r1 );
        is_deeply(
            $data,
            {
                want => {
                    $sha_pref.'0' => 1,
                    $sha_pref.'1' => 1,
                },
                caps => {
                    cap1 => 1,
                    cap2 => 1,
                    cap3 => 1,
                    cap4 => 1,
                },
            }
        );
    }

    # bad data
    {
        my ($r1, $w1) = ae_handle_pipe( 'pipe3' );

        write_git_pkt( $w1, "want foo\n" );

        throws_ok {
            read_client_want( $r1 );
        } qr{\bnot a valid 'want'};
    }
}

test_read_client_want();
done_testing();

