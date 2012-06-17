/*******************************************************************************
**
** Copyright (C) 2012 Rohan McGovern <rohan@mcgovern.id.au>
** 
** Permission is hereby granted, free of charge, to any person obtaining a copy
** of this software and associated documentation files (the "Software"), to deal
** in the Software without restriction, including without limitation the rights
** to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
** copies of the Software, and to permit persons to whom the Software is
** furnished to do so, subject to the following conditions:
** 
** The above copyright notice and this permission notice shall be included in all
** copies or substantial portions of the Software.
** 
** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
** IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
** FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
** AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
** LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
** OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
** SOFTWARE.
**
*******************************************************************************/

// vim: expandtab:ts=2:sw=2

"use strict";

var fs = require('fs');
var jslint = require('./3rdparty/JSLint.js');
var filename = process.argv[2];

function space(howmany) {
  var i, out = '';
  for (i = 0; i < howmany; ++i) {
    out += ' ';
  }
  return out;
}

function printError(err) {
  if (!err) {
    return;
  }
  console.log(
    "%s:%d: error: %s",
    filename,
    err.line,
    err.reason
  );
  if (!err.evidence) {
    return;
  }
  console.log(
    "%s\n%s^",
    err.evidence,
    space(err.character)
  );
}

fs.readFile(filename, 'utf-8', function (err, data) {
  var succeeded, errors, i;

  succeeded = jslint.JSLINT(
    data,
    {
      node: 1,          // using node.js
      plusplus: 1,      // allow ++ and --
      indent: 2,        // 2-space indent
      eqeq: 1,          // allow == and !=
      'continue': 1,    // allow continue
      'regexp': 1,      // allow . in regex
      nomen: 1,         // allow _ at begin/end of variable names
      white: 1          // no whitespace enforcement
    }
  );
  if (succeeded) {
    return;
  }

  errors = jslint.JSLINT.errors;
  for (i = 0; i < errors.length; ++i) {
    printError(errors[i]);
  }
});
