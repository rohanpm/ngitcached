use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'App::ngitcached',
    AUTHOR              => q{Rohan McGovern <rohan@mcgovern.id.au>},
    VERSION_FROM        => 'lib/App/ngitcached.pm',
    ABSTRACT_FROM       => 'lib/App/ngitcached.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    EXE_FILES           => [ 'bin/ngitcached' ],
    PREREQ_PM => {
        'Const::Fast' => 0,
        'Coro::AnyEvent' => 0,
        'Test::More' => 0,
        'Exporter::Simple' => 0,
        'AnyEvent::HTTP' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'App-ngitcached-*' },
);
