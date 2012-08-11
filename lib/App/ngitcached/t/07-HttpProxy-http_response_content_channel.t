use strict;
use warnings;

use AnyEvent::HTTP;
use Sub::Override;
use Test::Exception;
use Test::More;
use Test::NoWarnings;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::HttpProxy qw( http_response_content_channel );
use App::ngitcached::Proxy;

sub test_http_response_content_channel
{
    # basic success
    {
        my ($r_h, $w_h) = ae_handle_pipe( 'test pipe' );
        my ($c_http, $cv) = http_response_content_channel(
            $w_h,
            headers => {
                'Content-Type' => 'application/x-git-upload-pack-advertisement',
                Pragma => 'no-cache',
                'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
            },
        );

        $c_http->put( 'x' x 100000 );
        $c_http->shutdown();
        
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

        throws_ok {
            while (bread( {in=>$r_h,timeout=>0.4}, regex => qr{\r\n} )) {
            }
        } qr{\btest pipe\b.*\binternal pipe\b.*\bBroken pipe\b};

        $cv->recv();
    }


    # git pkt chunking
    {
        my ($r_h, $w_h) = ae_handle_pipe( 'test pipe' );
        my ($c_http, $cv) = http_response_content_channel(
            $w_h,
            headers => {
                'Content-Type' => 'application/x-git-upload-pack-advertisement',
                Pragma => 'no-cache',
                'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
            },
        );

        for my $i (1..2500) {
            write_git_pkt( $c_http, "test pkt $i\n" );
        }
        $c_http->shutdown();
        $cv->recv();

        bread( $r_h, regex => qr{\r\n\r\n} );

        # read each git pkt from chunks ...
        my $i = 1;
        while ($i <= 2500) {
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
test_http_response_content_channel();

