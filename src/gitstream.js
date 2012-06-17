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
  events: require('events'),
  util: require('util')
};
var myutil = require('./util.js');
var mylog = require('./log.js');

function GitStream(socket) {
  var gitstream = this,
    i,
    proxyevents = [ 'end', 'error', 'close' ],
    proxyfunctions = [ 'destroy', 'write', 'destroy', 'destroySoon' ];

  this._socket = socket;
  this._remainingData = null;
  this._useSideband = true;
  this._paused = false;
  this._queuedEmits = [];

  for (i = 0; i < proxyevents.length; ++i) {
    this._setProxyEvent(proxyevents[i]);
  }

  for (i = 0; i < proxyfunctions.length; ++i) {
    this._setProxyFunction(proxyfunctions[i]);
  }

  this._socket.on('data', function () {
    gitstream._onData.apply(gitstream, arguments);
  });
}

GitStream.prototype = new node.events.EventEmitter();
GitStream.prototype.constructor = GitStream;
exports.GitStream = GitStream;

GitStream.prototype._setProxyEvent = function (eventName) {
  var gitstream = this;
  this._socket.on(eventName, function () {
    var args = [];
    if (eventName == 'error') {
      mylog.log(0, 'GitStream error: ' + node.util.inspect(arguments));
    }
    if (arguments.length) {
      args = Array.prototype.slice.apply(arguments);
    }
    args.unshift(eventName);
    gitstream.emit.apply(gitstream, args);
  });
};

GitStream.prototype._setProxyFunction = function (functionName) {
  var gitstream = this;
  this[functionName] = function () {
    if (!gitstream._socket) {
      return;
    }
    gitstream._socket[functionName].apply(gitstream._socket, arguments);
  };
};

GitStream.prototype.pause = function () {
  this._socket.pause();
  this._paused = true;
};

GitStream.prototype.resume = function () {
  var gitstream = this;
  this._paused = false;

  process.nextTick(function () {
    gitstream._flushQueuedEmits();
    if (!gitstream._paused) {
      gitstream._socket.resume();
    }
  });
};

GitStream.prototype.socket = function () {
  return this._socket;
};

GitStream.prototype.writeMessage = function (message) {
  if (!this._socket) {
    mylog.log(1, 'GitStream: dropped write after fatal error: ' + message);
    return;
  }
  if (!(message instanceof Buffer)) {
    mylog.trace(0, 'GitStream.prototype.writeMessage was incorrectly passed a string; '
                 + 'encode to buffer first!');
    // well, it's better to continue and not crash, despite the caller's error ...
    message = new Buffer(message);
  }
  var to_write = this._formatPktLine(message);
  try {
    this._socket.write(to_write);
  } catch (e) {
    mylog.trace(1, 'GitStream: error writing to socket: ' + e);
    this._socket.destroySoon();
    this._socket.removeAllListeners('data');
    this._socket.on('data', function (d) {
      mylog.log(1, 'GitStream: dropped read after fatal error: ' + d);
    });
    this._socket = undefined;
  }
};

GitStream.prototype.writeFlush = function () {
  this._socket.write('0000');
};

GitStream.prototype._prefixHexLen = function (message) {
  var hexlen = (message.length + 4).toString(16);
  while (hexlen.length < 4) {
    hexlen = '0' + hexlen;
  }

  return myutil.bufcat(new Buffer(hexlen), message);
};


GitStream.prototype._formatPktLine = function (message) {
  if (!message || message.length == 0) {
    return new Buffer('0000');
  }

  return this._prefixHexLen(message);
};


GitStream.prototype._onData = function (data) {
  var i,
    msg,
    parsed;

  data = myutil.bufcat(this._remainingData, data);
  parsed = this._parsePktLine(data);
  this._remainingData = parsed.remaining;

  for (i = 0; i < parsed.messages.length; ++i) {
    msg = parsed.messages[i];
    this.emitMessage('message', msg);
    if (!msg.length) {
      this.emitMessage('flush', msg);
    }
    if (!msg.sideband) {
      continue;
    }
    if (msg.sideband == 1) {
      this.emitMessage('sideband1', msg);
    }
    if (msg.sideband == 2) {
      this.emitMessage('sideband2', msg);
    }
  }
};

GitStream.prototype.emitMessage = function (eventname, message) {
  if (!this._paused) {
    return this.emit(eventname, message);
  }
  this._queuedEmits.push([ eventname, message ]);
};

GitStream.prototype._flushQueuedEmits = function () {
  var emit, to_emit = this._queuedEmits;
  this._queuedEmits = [];
  while (to_emit.length) {
    emit = to_emit.shift();
    this.emitMessage(emit[0], emit[1]);
  }
};

GitStream.prototype._parsePktLine = function (data) {
  var out, hexlen, len, parsed, s;
  out = {
    messages: [],
    remaining: undefined
  };
  while (data != undefined && data.length >= 4) {
    hexlen = data.toString('utf8', 0, 4);
    len = parseInt(hexlen, 16);

    if (len > data.length) {
      // have partial data
      break;
    }

    // '0000' is special
    // Note that the first four bytes usually means the length _including_
    // this four byte length specifier, but not for this last message!
    // It should really be 0004 ...
    if (len == 0) {
      out.messages.push({
        rawdata: data.slice(0, 4),
        lendata: data.slice(0, 4),
        msgdata: new Buffer(0),
        length:  len
      });
      data = data.slice(4);
    } else {
      parsed = {
        rawdata: data.slice(0, len),
        lendata: data.slice(0, 4),
        msgdata: data.slice(4, len),
        length:  len
      };
      if (this._useSideband) {
        s = parsed.msgdata[0];
        if (s == 1 || s == 2 || s == 3) {
          parsed.sideband = s;
          parsed.sidebanddata = parsed.msgdata.slice(1);
        }
      }
      out.messages.push(parsed);
      data = data.slice(len);
    }
  }
  if (data != undefined && data.length) {
    out.remaining = data;
  }

  return out;
};

// vim: expandtab:ts=2:sw=2
