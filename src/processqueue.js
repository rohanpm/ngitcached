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

var node = {
  child_process: require('child_process'),
  events: require('events'),
  util: require('util')
};

function ProcessQueue(limit) {
  this._running = 0;
  this._queued = [];
  this._limit = limit;

  if (this._limit == undefined) {
    this._limit = 2;
  }
}

ProcessQueue.prototype = new node.events.EventEmitter();
ProcessQueue.prototype.constructor = ProcessQueue;
exports.ProcessQueue = ProcessQueue;

ProcessQueue.prototype.spawn = function () {
  this._queued.push({ args: arguments, func: 'spawn' });
  this._checkQueue();
};

ProcessQueue.prototype.exec = function () {
  this._queued.push({ args: arguments, func: 'exec' });
  this._checkQueue();
};

ProcessQueue.prototype._checkQueue = function () {
  var pq = this,
    data,
    new_arguments,
    new_function,
    new_process,
    exit_cb;

  exit_cb = function () {
    pq._onProcessExit();
  };

  while (this._running < this._limit && this._queued.length) {
    data = this._queued.shift();
    new_arguments = data.args;
    new_function = data.func;
    new_process = node.child_process[new_function].apply(node.child_process, new_arguments);
    new_process.on('exit', exit_cb);
    ++this._running;
  }
};

ProcessQueue.prototype._onProcessExit = function () {
  --this._running;
  this._checkQueue();
  if (!this._running) {
    this.emit('emptied');
  }
};

ProcessQueue.prototype.empty = function () {
  return (!this._running);
};

// vim: expandtab:ts=2:sw=2
