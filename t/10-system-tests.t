#!/usr/bin/env perl
################################################################################
##
## Copyright (C) 2012 Rohan McGovern <rohan@mcgovern.id.au>
## 
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
## 
## The above copyright notice and this permission notice shall be included in all
## copies or substantial portions of the Software.
## 
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
################################################################################
use strict;
use warnings;

use File::Basename;
use File::Spec::Functions;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;
use autodie;
use IPC::Open2;
use Getopt::Long qw(:config pass_through);

use Readonly;

Readonly my $TESTDIR => $FindBin::Bin;
Readonly my $SRCDIR => dirname( $TESTDIR );
Readonly my $NGITCACHED => catfile( $SRCDIR, qw(bin ngitcached) );
Readonly my $DATADIR => catfile( $TESTDIR, 'data' );

my $DEBUG = 0;

sub timed_readline
{
    my ($fh) = @_;

    my $timeout = 5;
    local $SIG{ALRM} = sub { diag "expected line did not arrive within $timeout seconds" };
    alarm $timeout;
    my $out = <$fh>;
    alarm 0;
    return $out;
}

sub start_ngitcached
{
    my ($args, %context) = @_;
    if (!$args) {
        $args = "";
    }

    my $tempdir = tempdir( 'ngitcached-system-tests-XXXXXX', TMPDIR => 1, CLEANUP => !$DEBUG );

    if ($DEBUG) {
        warn "Temporary directory will be retained at $tempdir\n";
    }

    my @cmd = ($NGITCACHED, '--cache-dir', "$tempdir/cache", split(/\s+/, $args));
    my $fh;

    no autodie; # to unbreak piping open

    my $pid = open($fh, '-|', @cmd);
    unless( ok( $pid, 'spawn ngitcached' ) ) {
        diag "spawn ngitcached: $!";
        return;
    }
    
    $context{ ngitcached }{ fh } = $fh;
    $context{ ngitcached }{ pid } = $pid;
    $context{ tempdir } = $tempdir;

    return %context;
}

sub stop_ngitcached
{
    my %context = @_;

    return %context unless $context{ ngitcached }{ pid };
    kill( 15, $context{ ngitcached }{ pid } );
    delete $context{ ngitcached }{ pid };

    return %context;
}

sub run_in_shell
{
    my ($line, %context) = @_;

    if (!exists $context{ sh }{ pid }) {
        my ($out_fh, $in_fh);
        $context{ sh }{ pid } = open2( $out_fh, $in_fh, '/usr/bin/setsid', '/bin/sh', '-s' )
            || die "run sh: $!";

        my $oldfh = select $out_fh;
        $|++;
        select $oldfh;

        print $in_fh "set -e\n";
        print $in_fh "trap \"trap - INT TERM EXIT; kill 0\" INT TERM EXIT\n";
        $context{ sh }{ in_fh } = $in_fh;
        $context{ sh }{ out_fh } = $out_fh;
    }

    my $in_fh = $context{ sh }{ in_fh };
    my $out_fh = $context{ sh }{ out_fh };

    print $in_fh "$line >/dev/null\necho OK\n";
    my $sh_line = <$out_fh>;
    ($sh_line && $sh_line eq "OK\n") || die "command $line failed";

    return %context;
}

sub test_one_data
{
    my ($datafile) = @_;

    open(my $fh, '<', $datafile);

    my %context;
    my $i = 0;
    
    while (my $line = <$fh>) {
        ++$i;
        chomp $line;
        $line =~ s{#.*\z}{};

        $line or next;

        if (exists $context{ tempdir }) {
            $line =~ s/%TEMPDIR%/$context{ tempdir }/g; 
        }
        $line =~ s/%TESTDIR%/$FindBin::Bin/g; 

        if ($line =~ m{\A start_ngitcached (.*)\z}xms) {
            if (exists $context{ ngitcached }) {
                die "${datafile}:${i}: error: start_ngitcached called while ngitcached "
                   .'already running';
            }

            %context = start_ngitcached $1, %context;
            next;
        }

        if ($line eq 'stop_ngitcached') {
            if (!exists $context{ ngitcached }) {
                die "${datafile}:${i}: error: stop_ngitcached called while gitcache not "
                   .'running';
            }
            %context = stop_ngitcached %context;
            next;
        }

        if ($line =~ m{\A out(\d+): [ ] (.*) \z}xms) {
            my ($verbosity, $text) = ($1, $2);
            unless (exists $context{ ngitcached }) {
                die "${datafile}:${i}: error: out$verbosity encountered prior to start_ngitcached";
            }

            my $ngitcached_fh = $context{ ngitcached }{ fh };
            my $actual_line = timed_readline $ngitcached_fh;
            $actual_line ||= q{};
            chomp $actual_line;
            is( $actual_line, $text, "${datafile}:${i} `out' match" ) || last;
            next;
        }

        # Anything else is fed to our interactive shell
        eval { %context = run_in_shell $line, %context };
        ok( !$@, "${datafile}:${i} shell command \"$line\" ok" ) || last;
    }
    close( $fh );

    if (exists $context{ sh }) {
        ok( close( $context{ sh }{ in_fh } ), 'sh close in OK' );
        ok( close( $context{ sh }{ out_fh } ), 'sh close out OK' );
        waitpid( $context{ sh }{ pid }, 0 );
    }

    %context = stop_ngitcached %context;

    my $remaining = "";
    my $ngitcached_fh = $context{ ngitcached }{ fh };
    while (my $line = timed_readline $ngitcached_fh) {
        $remaining .= $line;
    }
    if ($remaining) {
        diag "untested output from ngitcached:\n$remaining";
    }

    unless( ok( close($context{ ngitcached }{ fh }), 'ngitcached exited with 0 exit code' ) ) {
        diag "close ngitcached: $! (status=$?)";
        return;
    }

    return;
}

sub main
{
    my @data = sort glob "$DATADIR/*.txt";

    GetOptions(
        debug => \$DEBUG,
    ) || die $!;

    if (@ARGV == 1) {
        my $pattern = $ARGV[0];
        @data = grep { $_ =~ qr{$pattern} } @data;
    }

    foreach my $datafile (@data) {
        test_one_data $datafile;
    }
}

if (!caller) {
    main;
    done_testing;
}

1;
