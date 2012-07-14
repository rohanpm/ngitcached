use strict;
use warnings;

use Data::Dumper;
use Test::Exception;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../../..";
use App::ngitcached::Proxy;

sub test_rewrite_capabilities
{
    my $sha = ("0123456789" x 4);
    my $in = "$sha HEAD\x00quux bar thin-pack side-band baz no-done\n";
    is( rewrite_capabilities( $in ), "$sha HEAD\x00thin-pack side-band\n" );

    return;
}

test_rewrite_capabilities();
done_testing();
