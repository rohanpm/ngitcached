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

        my @result;
        
        $h_http->push_write( 'x' x 100000 );
        $h_http->push_shutdown();

        @result = bread( $r_h, regex => qr{\r\n\r\n} );
        is( $result[0], $r_h );
        my $headers = <<'END_HEADER';
HTTP/1.1 200 OK
Cache-Control: no-cache, max-age=0, must-revalidate
Pragma: no-cache
Transfer-Encoding: chunked
Content-Type: application/x-git-upload-pack-advertisement

END_HEADER
        $headers =~ s{\n}{\r\n}msg;
        is( $result[1], $headers );

        @result = bread( $r_h, regex => qr{\r\n} );
        is( $result[0], $r_h );
        $result[1] =~ s{\r\n$}{}ms;
        my $length = hex( $result[1] );

        @result = bread( $r_h, regex => qr{\r\n} );
        is( length( $result[1] ), $length + 2 );
        is( $result[1], ('x' x $length) . "\r\n" );

        # After the writer is undefined, the internal pipe write end is closed,
        # causing 'broken pipe' here.
        undef $h_http;

        throws_ok {
            while (bread( {in=>$r_h,timeout=>0.4}, regex => qr{\r\n} )) {
            }
        } qr{\btest pipe\b.*\binternal pipe\b.*\bBroken pipe\b};

        $cv->recv();
    }
}

plan( 'no_plan' );
test_http_response_content_handle();

