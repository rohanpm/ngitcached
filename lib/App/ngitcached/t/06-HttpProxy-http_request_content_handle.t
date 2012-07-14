use strict;
use warnings;

use AnyEvent::HTTP;
use Coro::AnyEvent;
use Coro;
use Sub::Override;
use Test::Exception;
use Test::More;
use Test::NoWarnings;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::HttpProxy qw( http_request_content_handle );
use App::ngitcached::Proxy qw( bread );

sub mock_http
{
    my (%content) = @_;

    my $out;

    my $do_request = sub {
        my $complete_cb = pop @_;
        ok( $complete_cb, 'complete cb is set' ) || return;

        my ($method, $url, %params) = @_;
        my $on_body_cb = $params{ on_body };

        my $data = $content{ "$method $url" };
        if (!ok( $data, "$method $url requested as expected" )) {
            $complete_cb->();
            return;
        }

        if (!ok( $on_body_cb, 'on_body cb is set' )) {
            $complete_cb->();
            return;
        }

        my $headers = $data->{ headers } || { Status => 200 };

        my @chunks = @{ $data->{ chunks } };
        my $do_next_chunk;
        $do_next_chunk = sub {
            if (!@chunks) {
                return $complete_cb->( undef, $headers );
            }
            my $chunk = shift @chunks;
            ++$out->{ chunks };
            if (ref($chunk) eq 'HASH') {
                my $w;
                $w = AE::timer( $chunk->{ sleep }, 0, sub {
                    undef $w;
                    $do_next_chunk->();
                });
                return;
            }
            if ($on_body_cb->( $chunk, $headers )) {
                AE::postpone { $do_next_chunk->() };
            } else {
                $out->{ aborted } = 1;
            }
        };
        AE::postpone { $do_next_chunk->() };
    };

    $out = {
        sub_ref => Sub::Override->new(
            'App::ngitcached::HttpProxy::http_request'
            =>
            $do_request
        ),
        chunks => 0,
    };

    return $out;
}

sub test_http_request_content_handle
{
    # basic success
    {
        my $mock = mock_http(
            'GET http://example.com/quux' => {
                chunks => ['123', '456', {sleep=>1}, '78']
            }
        );
        my $r_http = http_request_content_handle( GET => 'http://example.com/quux' );

        my $result = bread( $r_http, chunk => 4 );
        is( $result, '1234', 'correct data [1]' );

        $result = bread( $r_http, chunk => 4 );
        is( $result, '5678', 'correct data [2]' );

        # Reading should fail
        throws_ok {
            bread( $r_http, chunk => 4 );
        } qr{Broken pipe}, 'read fails with broken pipe';

        # All chunks written
        is( $mock->{ chunks }, 4 );
    }
    
    # cancel/abort
    {
        my $mock = mock_http(
            'GET http://example.com/quux' => {
                chunks => ['123', { sleep => 0.4 }, '456', '789'],
            }
        );
        http_request_content_handle( GET => 'http://example.com/quux' );
        Coro::AnyEvent::sleep 1;
        ok( $mock->{ chunks } < 4, 'not all chunks processed' );
        ok( $mock->{ aborted }, 'http request was aborted' );
    }
}

plan( 'no_plan' );
test_http_request_content_handle();

