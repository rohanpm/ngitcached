package App::ngitcached::HttpProxy;

use 5.010;
use strict;
use warnings;

use App::ngitcached::Proxy;
use App::ngitcached;
use parent 'App::ngitcached::Proxy';
use parent 'Exporter';

use AnyEvent::HTTP qw();
use AnyEvent::Handle;
use AnyEvent::Socket;
use Const::Fast;
use Data::Dumper;
use English qw( -no_match_vars );
use Guard;
use HTTP::Request;
use HTTP::Response;
use HTTP::Status qw( :constants );
use List::MoreUtils qw( any );
use Scalar::Util qw( weaken );

# Note: some servers (github.com) won't work correctly unless 'git/...' is the
# first thing in the User-Agent string.
const my $HTTP_USER_AGENT => "git/1.7.9.5 (ngitcached/$App::ngitcached::VERSION)";

our @EXPORT_OK = qw(
    http_request_content_handle
    http_response_content_handle
);

# Define own http_request for easy mocking
sub http_request
{
    my ($method, $url, @args) = @_;
    return AnyEvent::HTTP::http_request( $method, $url, @args );
}

sub read_http_headers
{
    my ($h) = @_;

    return bread( $h, regex => qr{\r\n\r\n} );
}

sub read_http_request
{
    my ($h) = @_;

    my $str = read_http_headers( $h );
    my $out = HTTP::Request->parse( $str );

    # basic sanity check on the parsing...
    if (!$out->method( )) {
        warn "bad HTTP request: $str\n";
        die { HTTP_BAD_REQUEST() => 'not an HTTP request' };
    }

    return $out;
}

sub read_http_response
{
    my ($h) = @_;

    my $str = read_http_headers( $h );
    my $out = HTTP::Response->parse( $str );

    # basic sanity check on the parsing...
    if (!$out->code( )) {
        warn "bad HTTP response: $str\n";
        die { HTTP_BAD_GATEWAY() => 'bad HTTP response from server' };
    }

    return $out;
}

sub write_http_error
{
    my ($h, $error) = @_;

    my $r = HTTP::Response->new( 500 );
    $r->protocol( 'HTTP/1.1' );

    if (ref($error)) {
        my ($code, $message) = %{ $error };
        if ($code !~ m{\A[0-9]+\z}) {
            die "code $code is not an integer\n";
        }
        $r->code( $code );
        $r->message( $message );
    } else {
        $r->message( $error );
    }

    AE::log( info => $r->code().' '.$r->message() );

    bwrite( $h, $r->as_string( "\r\n" ) );
    bshutdown( $h );

    $h->destroy();

    return;
}



sub http_request_content_handle
{
    my ($method, $url, %request_params) = @_;

    my $recursion = (delete $request_params{ _recursion }) // 0;
    if ($recursion && $recursion > 4) {
        die { HTTP_BAD_GATEWAY() => 'too many redirects' };
    }

    my $label = "http $method $url ->";
    my $cv = AE::cv();
    my ($r_h, $w_h) = ae_handle_pipe( $label, $cv );

    # Once the reader is destroyed, we can also destroy the writer
    $r_h->{ ngitcached_kill_other_end } = guard {
        if ($w_h) {
            $w_h->destroy();
            undef $w_h;
        }
    };

    my $weak_r_h = $r_h;
    weaken( $weak_r_h );

    my $got_data;

    AE::log debug => "calling http_request $method => $url";

    http_request(
        $method,
        $url,
        %request_params,
        on_body => sub {
            my ($data, $headers) = @_;

            AE::log trace => sub { printable("$label body: '$data'\n") };

            # Abort as soon as the read handle is discarded
            if (!$weak_r_h || !$w_h) {
                AE::log debug => "$label aborting, file handle destroyed";
                return;
            }

            eval { bwrite( $w_h, $data ) };
            if (my $error = $EVAL_ERROR) {
                $cv->croak( $error );
                AE::log debug => "$label aborting, error: '$error'";
                return;
            }
            if (!$got_data) {
                $got_data = 1;
                $cv->send( $headers );
            }
            return 1;
        },
        sub {
            # request complete, no more data to send
            my ($data, $headers) = @_;

            AE::log trace => sub {
                my $pdata = $data ? "'$data'" : '(no data)';
                printable("$label complete: $pdata\n");
            };

            if ($w_h) {
                eval { bshutdown( $w_h ) };
                if (my $error = $EVAL_ERROR) {
                    return $cv->croak( $error );
                }
            }

            if (!$got_data) {
                $cv->send( $headers );
            }
        }
    );

    AE::log debug => "$label: waiting for response headers...\n";
    my ($headers) = $cv->recv();
    AE::log debug => "$label: got response headers\n";

    # Note: we deliberately follow redirects proxy-side to support
    # HTTP -> HTTPS proxying more easily
    if ($headers->{ Status } =~ /^30[127]$/) {
        my $location = $headers->{ location };
        warn "redirect $url -> $location\n";
        undef $r_h;
        return http_request_content_handle(
            $method => $location,
            _recursion => $recursion + 1,
            %request_params
        );
    }

    if ($headers->{ Status } =~ /^4/) {
        die { $headers->{ Status } => $headers->{ Reason } };
    }

    if ($headers->{ Status } !~ /^2/) {
        die { HTTP_BAD_GATEWAY() => "$headers->{ Status } $headers->{ Reason }" };
    }

    return $r_h;
}

sub http_response_content_handle
{
    my ($h_http, %params) = @_;
    my $cv = AE::cv();

    my ($r_h, $w_h) = ae_handle_pipe( '-> http response' );

    my %headers = %{ $params{ headers } || {} };

    my $response = HTTP::Response->new( 200 );
    $response->protocol( 'HTTP/1.1' );
    $response->header( 'Transfer-Encoding' => 'chunked' );
    while (my ($key, $val) = each %headers) {
        $response->header( $key => $val );
    }

    my $push_write = sub {
        my ($data) = @_;
        AE::log trace => sub { printable("http response write: $data") };
        eval {
            bwrite( $h_http, $data );
        };
        if (my $error = $EVAL_ERROR) {
            $cv->croak( $error );
        }
        return;
    };

    my $write_chunk_cb = sub {
        AE::log trace => "http writing a chunk\n";

        my ($handle) = @_;
        my $data = q{};

        # if writing a git pkt, try to ensure a pkt is not
        # broken across http chunks
        my $pktlen;
        while ($handle->{ rbuf }) {
            if ($handle->{ rbuf } =~ m/\A([0-9a-fA-F]{4})/) {
                $pktlen = hex( $1 );
                AE::log trace => "http: chunk includes a git pkt of length 0x$1 / $pktlen";
                my $buflen = length( $handle->{ rbuf } );
                if ($buflen >= $pktlen) {
                    my $append = substr( $handle->{ rbuf }, 0, $pktlen > 4 ? $pktlen : 4, q{} );
                    AE::log trace => sub { "...appending to chunk: ".printable($append) };
                    $data .= $append;
                } else {
                    AE::log trace => "...but http rbuf only has $buflen bytes";
                    last;
                }
            } elsif (length($handle->{ rbuf }) >= 4) {
                $data = $handle->{ rbuf };
                $handle->{ rbuf } = q{};
            } else {
                last;
            }
        }

        if ($data) {
            my $hexlen = sprintf( '%0x', length( $data ) );
            $push_write->( "$hexlen\r\n$data\r\n" );
        } else {
            AE::log trace => sub {
                "http: not enough data for one chunk: need $pktlen, have "
               .length( $handle->{ rbuf } );
            };
        }
    };

    my $write_response_cb = sub {
        AE::log trace => "http writing response headers\n";

        my ($handle) = @_;
        $push_write->( $response->as_string("\r\n") );
        $handle->on_read( $write_chunk_cb );
    };

    my $write_last_chunk = sub {
        AE::log trace => "http writing terminating chunk\n";
        AE::log trace => sub { length( $r_h->{ rbuf } ) . ' bytes left in rbuf' };

        # Referring to $r_h in this callback ensures that the read end
        # of the pipe will not be destroyed until the write end closes
        # (or EOF caused somehow).
        $r_h->destroy();
        undef $r_h;

        $push_write->( "0\r\n\r\n" );
        push_end( $h_http );

        $cv->send();
    };

    $r_h->on_read( $write_response_cb );
    $r_h->on_eof( $write_last_chunk );

    # The reading end should live as long as the writing end.
    $w_h->{ ngitcached_other_pipe_end } = $r_h;

    return ($w_h, $cv);
}

sub protocol
{
    return 'http';
}

sub process_connection
{
    my ($self, $fh, $host, $port) = @_;

    my $h;
    $h = ae_handle(
        "incoming HTTP socket from $host:$port",
        fh => $fh,
        on_error => generic_handle_error_cb(),
    );

    eval {
        my $req = read_http_request( $h );
        my $method = $req->method();

        if ($method eq 'GET') {
            return $self->handle_http_get( $h, $req );
        }
        if ($method eq 'POST') {
            return $self->handle_http_post( $h, $req );
        }

        die { HTTP_METHOD_NOT_ALLOWED() => "$method not suppoted" };
    };

    if (my $error = $EVAL_ERROR) {
        chomp $error;
        eval {
            write_http_error( $h, $error );
        };
        if (my $error2 = $EVAL_ERROR) {
            chomp $error2;
            if ($error2 =~ m{\bBroken pipe\b}) {
                # Client disconnected, not an error
            } else {
                warn "$error\nAdditionally, failed to write HTTP error document: $error2\n";
            }
        }
    }

    return;
}

sub handle_http_get
{
    my ($self, $h, $request) = @_;

    AE::log( info => "Client request: ".$request->as_string() );

    my $uri = URI->new( $request->uri() );
    my %query = $uri->query_form();
    my $service = $query{ service };

    my $error;
    if (!$service) {
        $error = 'no service';
    } elsif ($service ne 'git-upload-pack') {
        $error = "service '$service' not implemented";
    }
    if ($error) {
        die { HTTP_BAD_REQUEST() => "$error, expect service=git-upload-pack" };
    }

    my $remote_id = $uri->host() . $uri->path();
    $remote_id =~ s{/info/refs\z}{};

    my $h_server;
    my $s_service;
    my $read_git_pkt = sub {
        return read_git_pkt( $h_server );
    };

    retry {
        $h_server = http_request_content_handle(
            GET => $request->uri(),
            headers => {
                'User-Agent' => $HTTP_USER_AGENT,
                Pragma => 'no-cache',
                Accept => '*/*',
            },
        );
        AE::log debug => "Attempting to read first git pkt.\n";

        # First line should be the service ...
        $s_service = $read_git_pkt->();
        AE::log debug => "read first packet: '$s_service'\n";
    };

    my ($h_client_git, $response_cv) = http_response_content_handle(
        $h,
        headers => {
            'Content-Type' => 'application/x-git-upload-pack-advertisement',
            Pragma => 'no-cache',
            'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
        }
    );

    write_git_pkt( $h_client_git, $s_service );
    chomp $s_service;
    if ($s_service ne '# service=git-upload-pack') {
        warn "warning: unexpected git service: $s_service\n";
    }

    # Then a flush
    $read_git_pkt->();
    write_git_pkt( $h_client_git );

    # Then HEAD and caps
    my $pkt = $read_git_pkt->();
    ($pkt) || die { HTTP_BAD_GATEWAY() => 'no HEAD/caps pkt from server' };

    write_git_pkt( $h_client_git, rewrite_capabilities( $pkt ) );

    # Then read until next flush
    my $server_refs = {};
    while (my $pkt = $read_git_pkt->()) {
        AE::log debug => "read ref: '$pkt'\n";
        if (
            $pkt =~ m{
                \A
                ([0-9a-f]{40})
                [ ]
                (refs/.+)
                \n
                \z
            }xms
        ) {
            my ($sha1, $ref) = ($1, $2);
            $server_refs->{ $ref } = $sha1;
        }
        write_git_pkt( $h_client_git, $pkt );
    }
    write_git_pkt( $h_client_git );

    AE::log debug => sub { "refs on $remote_id: " . Dumper( $server_refs ) };

    $self->{ last_known_refs }{ $remote_id } = $server_refs;

    push_end( $h_client_git );

    # Wait until the response is entirely written
    $response_cv->recv();

    return;
}

sub handle_from_post_data
{
    my ($h, $request) = @_;

    my $length = $request->header( 'Content-Length' );
    if (!$length) {
        die { HTTP_BAD_REQUEST() => 'Content-Length is required' };
    }
    if ($length > 1000000) {
        die { HTTP_BAD_REQUEST() => 'Content-Length is too large' };
    }

    my $data = bread( $h, chunk => $length );

    AE::log trace => sub { printable("POST data: '$data'") };

    my ($r_h, $w_h) = ae_handle_pipe( 'POST data' );
    $w_h->push_write( $data );
    $w_h->push_shutdown( );
    return $r_h;
}

sub handle_http_post
{
    my ($self, $h, $request) = @_;

    AE::log trace => sub { 'incoming POST: ' . Dumper( $request ) };

    my $uri = URI->new( $request->uri() );
    if ($uri->path() !~ m{/git-upload-pack\Z}) {
        die { HTTP_BAD_REQUEST() => 'only POST to git-upload-pack are supported' };
    }

    my $remote_id = $uri->host() . $uri->path();
    $remote_id =~ s{/git-upload-pack\Z}{};

    my $remote_refs = $self->{ last_known_refs }{ $remote_id };
    AE::log debug => sub { 'last known refs: '.Dumper( $remote_refs ) };

    my $h_postdata = handle_from_post_data( $h, $request );

    my $client = read_client_want( $h_postdata );

    # then haves
    $client = { %{ $client } , %{ read_client_have( $h_postdata ) } };

    AE::log info => sub { 'git-upload-pack request: '.Dumper( $client ) };

    my $request_body;
    
    # reply all wants
    my $suffix = ' '.join( ' ', keys %{ $client->{ caps } } );
    foreach my $want ( keys %{ $client->{ want } } ) {
        write_git_pkt( \$request_body, "want $want$suffix\n" );
        $suffix = q{};
    }
    write_git_pkt( \$request_body );

    # then haves
    foreach my $have ( keys %{ $client->{ have } } ) {
        write_git_pkt( \$request_body, "have $have\n" );
    }
    write_git_pkt( \$request_body, "done\n" );

    my $server_request_h = http_request_content_handle(
        POST => $request->uri(),
        body => $request_body,
        headers => {
            'User-Agent' => $HTTP_USER_AGENT,
            'Content-Type' => $request->header( 'Content-Type' ),
            'Accept' => $request->header( 'Accept' ),
        },
    );

    my ($h_client_git, $response_cv) = http_response_content_handle(
        $h,
        headers => {
            'Content-Type' => 'application/x-git-upload-pack-result',
            Pragma => 'no-cache',
            'Cache-Control' => 'no-cache, max-age=0, must-revalidate',
        }
    );

    pump( $server_request_h, $h_client_git )->recv();

    AE::log debug => 'waiting for response to drain...';
    $response_cv->recv();
    AE::log debug => 'response fully written';

    return;
}

1;
