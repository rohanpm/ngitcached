package App::ngitcached;

use 5.010;
use strict;
use warnings;

BEGIN {
our $VERSION = '2';
}

use AnyEvent::Socket;
use AnyEvent;
use App::ngitcached::GitProxy;
use App::ngitcached::HttpProxy;
use Carp qw( cluck );
use Coro::AnyEvent;
use EV;
use English qw( -no_match_vars );
use Getopt::Long qw( GetOptionsFromArray );
use Pod::Usage qw( pod2usage );

sub new
{
    my ($class) = @_;
    return bless {
        git_port => 39418,
        http_port => 8080,
    }, $class;
}

sub run_proxies
{
    my ($self) = @_;

    my $git_server = App::ngitcached::GitProxy->server(
        undef,
        $self->{ git_port },
    );
    print "Listening on $self->{ git_port } for git connections\n";

    my $http_server = App::ngitcached::HttpProxy->server(
        undef,
        $self->{ http_port },
    );
    print "Listening on $self->{ http_port } for http connections\n";

    my $cv = AE::cv( );
    my $on_signal = sub {
        print "Terminating due to signal.\n";
        undef $git_server;
        undef $http_server;
        $cv->send( );
    };

    my @w =
        map {
            AE::signal( $_ => $on_signal )
        } qw(TERM INT);
    
    $cv->recv( );

    return;
}

sub run
{
    my ($self, @args) = @_;

    my $cache_dir;

    GetOptionsFromArray(
        \@args,
        'git-port=i' => \$self->{ git_port },
        'http-port=i' => \$self->{ http_port },
        'cache-dir=s' => \$cache_dir,
        'h|help' => sub { pod2usage(2) },
    ) || die $!;

    local $OUTPUT_AUTOFLUSH = 1;

    $self->run_proxies();

    return;
}

1;
