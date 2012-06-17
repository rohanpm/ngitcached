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

"use strict";

var mylog = require('./log.js');

/*
    Returns a slice of data excluding any trailing \n
*/
exports.chomp = function (data) {
  if (!data) {
    return data;
  }
  while (data.length && data[data.length - 1] == 10) {
    data = data.slice(0, data.length - 1);
  }
  return data;
};

/*
    Returns two buffers catenated
*/
exports.bufcat = function (buf1, buf2) {
  if (buf1 == undefined || buf1.length == 0) {
    return buf2;
  }
  if (buf2 == undefined || buf2.length == 0) {
    return buf1;
  }

  var newbuf = new Buffer(buf1.length + buf2.length);
  buf1.copy(newbuf);
  buf2.copy(newbuf, buf1.length);

  return newbuf;
};

exports.robustly = function (ctx) {
  var out;

  if (undefined == ctx._start_time) {
    ctx._start_time = (new Date()).getTime();
    ctx._end_time = ctx._start_time + ctx.maxtime;
    ctx._interval = ctx.interval;
    if (ctx._interval == undefined) {
      ctx._interval = 1000;
    }
  }

  out = ctx.fn.call(ctx, function () {
    clearTimeout(ctx._timeout_id);
    mylog.log(2, 'robustly: ' + ctx.label + ' completed');
    ctx.fn_on_complete.call(ctx, out);
  });

  out.once('error', function (ex) {
    var backoff = ctx.fn_on_error.call(ctx, ex),
      now,
      interval;

    mylog.log(2, 'robustly: ' + ctx.label + ' error ' + ex + ', backoff: ' + backoff);

    if (backoff == undefined || backoff <= 0) {
      clearTimeout(ctx._timeout_id);
      return;
    }

    now = (new Date()).getTime();
    if (now > ctx._end_time) {
      mylog.log(1, 'robustly: ' + ctx.label + ' giving up!');
      if (undefined != ctx.fn_on_give_up) {
        ctx.fn_on_give_up.call(ctx, ex);
      }
      clearTimeout(ctx._timeout_id);
      return;
    }

    interval = ctx._interval;

    mylog.log(2, 'robustly: ' + ctx.label + ' retry in ' + interval);

    ctx._interval *= backoff;
    ctx._timeout_id = setTimeout(
      exports.robustly,
      interval,
      ctx
    );
  });

  return;
};

// vim: expandtab:ts=2:sw=2
