use strict;
use warnings;

use AnyEvent::HTTP;
use Sub::Override;
use Test::Exception;
use Test::More;
use Test::NoWarnings;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::HttpProxy qw( http_response_content_handle );
use App::ngitcached::Proxy;

sub test_http_response_content_handle
{
    # basic success
    {
        my ($r_h, $w_h) = ae_handle_pipe( 'test pipe' );
        my ($h_http, $cv) = http_response_content_handle(
            $w_h,
            headers => {
                'Content-Type' => 'application/x-git-upload-pack-advertisement',
                Pragma => 'no-cache',
                'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
            },
        );

        $h_http->push_write( 'x' x 100000 );
        $h_http->push_shutdown();

        my $result = bread( $r_h, regex => qr{\r\n\r\n} );
        my $headers = <<'END_HEADER';
HTTP/1.1 200 OK
Cache-Control: no-cache, max-age=0, must-revalidate
Pragma: no-cache
Transfer-Encoding: chunked
Content-Type: application/x-git-upload-pack-advertisement

END_HEADER
        $headers =~ s{\n}{\r\n}msg;
        is( $result, $headers );

        $result = bread( $r_h, regex => qr{\r\n} );
        $result =~ s{\r\n$}{}ms;
        my $length = hex( $result );

        $result = bread( $r_h, regex => qr{\r\n} );
        is( length( $result ), $length + 2 );
        is( $result, ('x' x $length) . "\r\n" );

        # After the writer is undefined, the internal pipe write end is closed,
        # causing 'broken pipe' here.
        undef $h_http;

        throws_ok {
            while (bread( {in=>$r_h,timeout=>0.4}, regex => qr{\r\n} )) {
            }
        } qr{\btest pipe\b.*\binternal pipe\b.*\bBroken pipe\b};

        $cv->recv();
    }


    # git pkt chunking
    {
        my ($r_h, $w_h) = ae_handle_pipe( 'test pipe' );
        my ($h_http, $cv) = http_response_content_handle(
            $w_h,
            headers => {
                'Content-Type' => 'application/x-git-upload-pack-advertisement',
                Pragma => 'no-cache',
                'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
            },
        );

        for my $i (1..5000) {
            write_git_pkt( $h_http, "test pkt $i\n" );
        }
        undef $h_http;  # no more to write
        $cv->recv();

        bread( $r_h, regex => qr{\r\n\r\n} );

        # read each git pkt from chunks ...
        my $i = 1;
        while ($i <= 5000) {
            my $len = bread( $r_h, regex => qr{[0-9a-fA-F]+\r\n} );
            $len =~ s{\r\n}{};
            $len = hex($len);
            my $chunk = bread( $r_h, chunk => $len );
            bread( $r_h, chunk => 2 );  # \r\n

            my $orig_chunk = $chunk;

            while ($chunk) {
                my $pktlen = hex( substr( $chunk, 0, 4, q{} ) );
                $pktlen -= 4;
                ok($pktlen > 0, 'valid pktlen') || diag( $orig_chunk );
                ok(length( $chunk ) >= $pktlen, 'no partial pkt')
                    || diag( "chunk contains partial git pkts: $orig_chunk" );
                my $pkt = substr( $chunk, 0, $pktlen, q{} );
                is( $pkt, "test pkt $i\n" )
                    || diag( "pktlen: $pktlen" );
                ++$i;
            }
        }

    }
}

plan( 'no_plan' );
test_http_response_content_handle();

