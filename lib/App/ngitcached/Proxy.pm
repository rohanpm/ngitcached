package App::ngitcached::Proxy;

use 5.010;
use strict;
use warnings;

use AnyEvent::Handle;
use Carp;
use Const::Fast;
use Coro;
use English qw( -no_match_vars );
use Guard;

use parent 'Exporter';

our @EXPORT = qw(
    %CAPABILITIES
    ae_handle
    ae_handle_pipe
    bread
    bshutdown
    bwrite
    generic_handle_error_cb
    printable
    pump
    push_end
    read_client_have
    read_client_want
    read_git_pkt
    rewrite_capabilities
    safe_hex
    write_git_pkt
);

const our %CAPABILITIES => map { $_ => 1 } qw(
    thin-pack
    no-progress
    include-tag
    side-band
    side-band-64k
);

#==================== static ==================================================

sub printable
{
    my ($data) = @_;
    $data =~ s{[^\x01-x7f]}{.}g;
    return $data;
}

sub pump
{
    my ($from, $to) = @_;

    my $cv = AE::cv();

    $from->on_error( generic_handle_error_cb( $cv ) );
    $to->on_error( generic_handle_error_cb( $cv ) );

    $from->on_read(
        sub {
            my ($h) = @_;
            $to->push_write( $h->{ rbuf } );
            $h->{ rbuf } = q{};
        }
    );

    $from->on_eof(
        sub {
            eval {
                bshutdown( $to );
            };
            if (my $error = $EVAL_ERROR) {
                $cv->croak( $error );
            } else{
                $cv->send();
            }
        }
    );

    return $cv;
}

sub generic_handle_error_cb
{
    my ($cv) = @_;

    my $coro = $Coro::current;

    my (@caller) = caller();
    my $caller_str = "$caller[1] line $caller[2]";

    return sub {
        my ($h, $fatal, $msg) = @_;

        my $name = $h->{ ngitcached_name } || '(unknown handle)';

        my $type = ($fatal ? 'fatal error' : 'error');

        if ($msg) {
            $msg = ": $msg";
        } else {
            $msg = q{};
        }

        $msg = "$type on handle $name$msg";

        if ($cv && !$cv->ready()) {
            AE::log debug => "sending to cv: $msg";
            $cv->croak( $msg );
            # if the same error happens again, it is unexpected (ignored)
            undef $cv;
        } elsif ($coro && !$coro->is_zombie()) {
            if ($Coro::current == $coro) {
                AE::log debug => "raising: $msg";
                die $msg;
            }
            AE::log debug => "coro $Coro::current->{ desc } sending to coro $coro->{ desc }: $msg";
            $coro->throw( $msg );
        } else {
            warn "Unexpected $msg\n  This may be a bug in ngitcached.\n";
        }
    }
}

sub ae_handle
{
    my ($name, @args) = @_;

    my $out = AnyEvent::Handle->new( @args );
    $out->{ ngitcached_name } = $name;

    return $out;
}

#sub ae_handle_to_buffer
#{
#    my ($r, $w) = ae_handle_pipe( 'buffer' );
#
#    my $cv = AE::cv( );
#    my $buf = q{};
#
#    $r->on_read(
#        sub {
#            my ($h) = @_;
#            $buf .= $h->{ rbuf };
#            $h->{ rbuf } = q{};
#        }
#    );
#
#    $r->on_write(
#}

sub ae_handle_pipe
{
    my ($name, $cv) = @_;
    $name //= '(unknown handle)';

    my ($r_fh, $w_fh);
    pipe( $r_fh, $w_fh ) || die "pipe: $!";

    my $r_h = ae_handle(
        "$name internal pipe (reader)",
        fh => $r_fh,
        on_error => generic_handle_error_cb( $cv ),
    );
    my $w_h = ae_handle(
        "$name internal pipe (writer)",
        fh => $w_fh,
        on_error => generic_handle_error_cb( $cv ),
    );

    return ($r_h, $w_h);
}

# bread - blocking read
sub bread
{
    my ($in, @params) = @_;

    my $h = $in;
    my $timeout;
    if (ref($h) eq 'HASH') {
        $h = $in->{ in } || confess 'internal error: missing handle';
        $timeout = $in->{ timeout };
    }
    $timeout ||= 60*60*24;

    my $cv = AE::cv();
    my $error_cb = generic_handle_error_cb( $cv );

    $h->timeout( $timeout );
    $h->on_error( sub {
        $error_cb->( @_ );
        $h->destroy();
    });

    $h->unshift_read(
        @params,
        sub { $cv->send( @_ ) },
    );

    my (undef, $data) = $cv->recv();
    return $data;
}

sub io_or_die
{
    my ($h, $sub) = @_;

    my $guard = guard {
        $h->on_error( generic_handle_error_cb() );
    };

    $h->on_error(sub {
        my ($handle, undef, $message) = @_;
        my $name = $handle->{ ngitcached_name } || '(unknown handle)';
        die "error on handle $name: $message\n";
    });

    return $sub->( $h );
}

# bwrite - blocking write.
# $h may be an AnyEvent::Handle or a scalar ref.
sub bwrite
{
    my ($h, @params) = @_;

    if (ref($h) eq 'SCALAR') {
        if (@params != 1) {
            croak "internal error: bwrite with named parameters is incompatible with scalar ref";
        }
        $$h .= $params[0];
        return;
    }

    return io_or_die( $h, sub {
        shift->push_write( @params );
    });
}

# bshutdown - blocking shutdown
sub bshutdown
{
    my ($h) = @_;

    return io_or_die( $h, \&push_end );
}

# like push_shutdown, but close()s non-shutdownable fh
sub push_end
{
    my ($h) = @_;
    delete $h->{ low_water_mark };
    $h->on_drain(sub {
        my $handle = shift;
        my $fh = $handle->fh();
        if (!shutdown( $fh, 1 )) {
            my $shutdown_error = $!;
            if (!close( $fh )) {
                my $name = $handle->{ ngitcached_name } || '(unknown handle)';
                warn "could not shutdown or close $name\n"
                    ."  shutdown: $shutdown_error\n"
                    ."  close: $!\n";
            }
        }
    });
}

sub safe_hex
{
    my ($str) = @_;

    $str =~ s{\A0x}{};
    if ($str !~ m{\A[0-9a-fA-F]+\z}) {
        die "expected a hex string, got: $str\n";
    }

    return hex( $str );
}

# Read and return a git pkt from $h.
# Only the content is returned, not the length prefix.
# Returns nothing on a flush pkt.
sub read_git_pkt
{
    my ($h) = @_;

    my $hex_length = bread( $h, chunk => 4 );
    my $length = safe_hex( $hex_length );

    if ($length == 0) {
        return;
    }
    if ($length == 4) {
        return q{};
    }

    if ($length < 4) {
        die "corrupt git pkt, impossible length of $length\n";
    }
    
    # 4 bytes already used by length
    $length -= 4;

    if ($length == 0) {
        return;
    }

    return bread( $h, chunk => $length );
}

# Write a git pkt to $h
sub write_git_pkt
{
    my ($h, $data) = @_;

    if (!defined( $data )) {
        bwrite( $h, '0000' );
        return;
    }

    my $length = length( $data ) + 4;
    if ($length > 65535) {
        die 'git pkt data is too large to write';
    }

    my $hex_length = sprintf( '%04x', $length );
    bwrite( $h, "$hex_length$data" );

    return;
}

sub rewrite_capabilities
{
    my ($pkt) = @_;

    my ($ref, $in_caps) = split( /\x00/, $pkt, 2 );
    chomp $in_caps;

    my @in_caps = split( / /, $in_caps );
    my @out_caps = grep { exists $CAPABILITIES{ $_ } } @in_caps;

    return "$ref\x00@out_caps\n";
}

sub read_client_want
{
    my ($h) = @_;

    my $out = { want => {}, caps => {} };

    while (my $pkt = read_git_pkt( $h )) {
        chomp( $pkt );
        if (
            $pkt !~ m{
                \A
                want[ ]
                ([0-9a-f]{40})  # wanted SHA1
                (?: [ ](.+))?   # capabilities
                \z
            }xms
        ) {
            die "git pkt '$pkt' is not a valid 'want'";
        }

        $out->{ want }{ $1 } = 1;
        if ($2) {
            $out->{ caps } = {
                map { $_ => 1 } split( / /, $2 )
            };
        }
    }

    return $out;
}

sub read_client_have
{
    my ($h) = @_;

    my $out = { have => {} };

    while (my $pkt = read_git_pkt( $h )) {
        chomp( $pkt );

        if ($pkt eq 'done') {
            last;
        }

        if (
            $pkt !~ m{
                \A
                have[ ]
                ([0-9a-f]{40})  # wanted SHA1
                \z
            }xms
        ) {
            die "git pkt '$pkt' is not a valid 'have'";
        }

        $out->{ have }{ $1 } = 1;
    }

    return $out;
}

#=================== instance =================================================

sub server
{
    my ($class, $host, $service) = @_;
    my $self = bless {}, $class;
    $self->{ guard } = AnyEvent::Socket::tcp_server(
        $host,
        $service,
        sub {
            $self->spawn_handler( @_ );
        },
    );
    return $self;
}

sub set_state
{
    my ($self, $state) = @_;

    $self->{ coro }{ $Coro::current }{ state } = $state;

    return;
}

sub spawn_handler
{
    my ($self, $fh, $host, $port) = @_;

    async {
        $self->set_state( 'spawned' );
        AE::log info => "incoming connection: $host:$port\n";
        eval {
            $self->process_connection( $fh, $host, $port );
        };
        if (my $error = $EVAL_ERROR) {
            chomp $error;
            AE::log( note => $self->protocol( ) . " $host $port: dropped connection: $error\n" );
        }
        AE::log info => "finished connection: $host:$port\n";
        delete $self->{ coro }{ $Coro::current };
    };

    return;
}

1;
