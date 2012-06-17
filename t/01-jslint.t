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
use FindBin;
use Readonly;
use Test::More;

Readonly my $TESTDIR => $FindBin::Bin;
Readonly my $SRCDIR => dirname( $TESTDIR );

sub jslint_command
{
    my ($filename) = @_;

    return (
        'node',
        "$TESTDIR/jslint-one-file.js",
        $filename
    );
}

sub test_one_jslint
{
    my ($js_file) = @_;

    my @command = jslint_command( $js_file );
    my $out = qx( @command );

    is( $?, 0, "$js_file : exit code OK" );

    ok( !$out, "$js_file : no errors" )
        || diag $out;

    return;
}

sub test_all_jslint
{
    my @js = glob "$SRCDIR/src/*.js";

    plan tests => 2*scalar(@js);

    foreach my $js (@js) {
        test_one_jslint $js;
    }

    return;
}

if (!caller) {
    test_all_jslint;
    done_testing;
}

1;
