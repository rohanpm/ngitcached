package App::ngitcached::Coro;

use strict;
use warnings;

use AnyEvent;
use Carp qw(croak confess carp cluck);
use Coro;
use List::MoreUtils qw(firstidx);
use Scalar::Util qw(weaken refaddr);
use parent 'Exporter';

use overload
    '&{}' => \&_sub_overload,
;

our @EXPORT = qw(
    nrouse_cb
    nrouse_wait
    nrouse_die
);

# private, but accessed by tests
our %CB_BY_CORO;
our %LAST_CB_BY_CORO;

my $OK = 1;
my $ERROR = 2;

sub _new
{
    my ($class) = @_;
    my $coro = $Coro::current;

    my $out = bless {
        coro => $coro,
        coro_cb => Coro::rouse_cb( ),
    }, $class;

    push @{ $CB_BY_CORO{ $coro }}, $out;
    weaken( $CB_BY_CORO{ $coro }[-1] );

    # LAST_CB_BY_CORO must hold a _strong_ reference to ensure that
    # code of this form works:
    #
    #   nrouse_cb()->('hello');
    #   (nrouse_wait() == 'hello') || die;
    #
    # Then we need to ensure this reference is removed when
    # the coro is destroyed.
    if (!exists( $LAST_CB_BY_CORO{ $coro } )) {
        $coro->on_destroy(
            sub {
                delete $LAST_CB_BY_CORO{ $coro } if $coro;
            }
        );
    }

    $LAST_CB_BY_CORO{ $coro } = $out;
    return $out;
}

sub DESTROY
{
    my ($self) = @_;
    my $coro = $self->{ coro };
    return unless $coro;

    my $idx = firstidx { refaddr($_) == refaddr($self) } @{ $CB_BY_CORO{ $coro } || []};
    if ($idx != -1) {
        splice( @{ $CB_BY_CORO{ $coro } }, $idx, 1 );
        if (@{ $CB_BY_CORO{ $coro } } == 0) {
            delete $CB_BY_CORO{ $coro };
        }
    }

    return;
}

sub _sub_overload
{
    my ($self) = @_;
    return sub {
        $self->{ coro_cb }->( $OK, @_ );
    }
}

sub _caller_str
{
    my ($level) = @_;
    $level //= 1;
    my (undef, $filename, $line) = caller($level);
    return "$filename line $line";
}

sub nrouse_cb
{
    return __PACKAGE__->_new();
}

sub nrouse_wait
{
    my ($cb) = @_;
    if (! defined $cb) {
=cut
        if (!@{ $CB_BY_CORO{ $Coro::current } || []}) {
            confess 'internal error: nrouse_wait called with no existing nrouse_cb';
        }
        $cb = $CB_BY_CORO{ $Coro::current }[-1];
=cut
        if (!exists( $LAST_CB_BY_CORO{ $Coro::current } )) {
            confess 'internal error: nrouse_wait called with no existing nrouse_cb';
        }
        $cb = $LAST_CB_BY_CORO{ $Coro::current };
    }
    
    AE::log trace => sub { "start nrouse_wait from " . _caller_str(4) };
    my ($result, @rest) = Coro::rouse_wait( $cb->{ coro_cb } );
    AE::log trace => sub { "end nrouse_wait from " . _caller_str(4) };

    if (! defined $result) {
        # this happens when calling rouse_wait on an already waited
        # for cb
        return;
    }

    if ($result == $OK) {
        return wantarray ? @rest : $rest[-1];
    }
    croak $rest[0];
}

# nrouse_die will cause _all_ cb associated with $coro to die with $error
sub nrouse_die
{
    my ($coro, $error) = @_;
    my $cb_ref = $CB_BY_CORO{ $coro || $Coro::current };
    if ($cb_ref) {
        foreach my $coro_cb (map { $_->{ coro_cb } } @{ $cb_ref }) {
            $coro_cb->( $ERROR, $error );
        }
    } else {
        cluck "Unexpected error (ignored): $error\n";
    }
    return;
}

1;
