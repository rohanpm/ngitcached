package App::ngitcached::GitProxy;

use 5.010;
use strict;
use warnings;

use App::ngitcached::Proxy;
use parent 'App::ngitcached::Proxy';

use AnyEvent::Handle;
use AnyEvent::Socket;
use English qw( -no_match_vars );

sub protocol
{
    return 'git';
}

sub process_connection
{
    my ($self, $fh, $host, $port) = @_;

    my $h = ae_handle(
        "incoming git connection from $host:$port",
        fh => $fh,
        on_error => generic_handle_error_cb(),
    );

    eval {
        $self->process_git_connection( $h, $host, $port );
    };
    if (my $error = $EVAL_ERROR) {
        eval {
            write_git_pkt( $h, "ERR \n ngitcached: $error" );
        };
        die $error;
    }
    return;
}

sub process_git_connection
{
    my ($self, $h, $host, $port) = @_;

    my $service_pkt = read_git_pkt( $h );
    if (
        # initial packet format:
        # "git-upload-pack /some/path\x00host=example.com:9418\x00"
        # Note: it's unclear if there may ever be parameters other
        # than 'host'
        $service_pkt !~ m{
            \A
            git-upload-pack
            [ ]
            ([^\x00]+) # git-upload-pack path
            \x00
            host=([^\x00]+)
            \x00
        }xms
    ) {
        die "bad service request: '$service_pkt'";
    }

    my ($path, $s_host, $s_port) = ($1, split(/:/, $2, 2));
    $s_port //= 9418;

    my $s_h = ae_handle(
        "tcp connection to $s_host:$s_port on behalf of $host:$port",
        connect => [$s_host, $s_port],
        on_error => generic_handle_error_cb(),
    );
    write_git_pkt( $s_h, $service_pkt );

    my $pkt = read_git_pkt( $s_h );
    $pkt || die "unexpected flush pkt\n";
    write_git_pkt( $h, rewrite_capabilities( $pkt ) );

    my $pump_client_to_server = pump( $h, $s_h );
    my $pump_server_to_client = pump( $s_h, $h );

    $pump_client_to_server->recv();
    $pump_server_to_client->recv();

    return;
}

1;
