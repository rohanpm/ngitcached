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
  fs: require('fs'),
  net: require('net'),
  url: require('url'),
  util: require('util'),
  events: require('events'),
  child_process: require('child_process')
};

var _ = require('underscore');
var ignite = require('ignite');

var myutil = require('./util.js');
var mylog = require('./log.js');
var GitStream = require('./gitstream.js').GitStream;
var ProcessQueue = require('./processqueue.js').ProcessQueue;

var GIT_PORT = 9418;

var CACHE_HOT = 1,
  CACHE_COLD = 2,
  CACHE_WARM = 3,
  CACHE_NO_OBJECTS_REQUESTED = 4;

var REASON_EXIT = 1,
  REASON_ERROR = 2;

/* ====================== GitProxyConnection ============================== */

function GitProxyConnection(client) {
  this.client = {
    stream: new GitStream(client),
    want: {}
  };
  this.server = {
    stream: null,
    refs_by_ref: {},
    refs_by_sha: {},
    refs_by_order: [],
    port: GIT_PORT,
    host: null,
    caps: []
  };
  this.want = {};
  this.sidebandTwoFromServerToClient = [];

  var gitproxy = this;
  this.client.stream.on('error', function (ex) {
    gitproxy.onClientSocketError(ex);
  });
}

GitProxyConnection.prototype = new node.events.EventEmitter();
GitProxyConnection.prototype.constructor = GitProxyConnection;

/*
  Example simple session:

   1. client connects to proxy.

   2. proxy connects to server.

   3. proxy finds list of ref/sha1 pairs from server.

   4. proxy forwards ref/sha1 pairs to client.

   5. client sends all wants, then flush.

   6. client begins sending haves; proxy does not read these yet.

   7. proxy forwards client's wants (minus those the proxy already has),
      and proxy's haves, to server.
      proxy's haves may come from listing all refs for this server,
      or all refs for every server.

   8. proxy receives pack file from server (index-pack), updates refs
      (one copy namespaced to this connection, which can be trusted;
       one copy namespaced to the server, which could be clobbered at
       any time)

   9. proxy launches git-upload-pack on itself; the git-upload-pack
      preamble output is discarded; the proxy replays the client's
      wants to git-upload-pack, then connects the client's stream
      (with haves still pending) to the proxy's upload-pack.
*/

GitProxyConnection.prototype.onClientSocketError = function (ex) {
  mylog.log(1, "client socket error: '" + ex + "', dropping connection");
  this.client.stream.destroy();
  this.server.stream.destroy();
};

GitProxyConnection.prototype.handleClientChunk1 = function (message, cb) {
  var chunk,
    chunks,
    data,
    host,
    keyvalue,
    parsed_url,
    prefix,
    repo,
    split_host,
    split_remote;

  message = message.msgdata;

  chunks = message.toString().split('\x00');
  mylog.log(2, node.util.inspect(chunks));

  // Expected chunks:
  //  git-upload-pack /some/repo.git
  //  key=value
  //  ...
  //  (empty)
  prefix = 'git-upload-pack ';
  repo = chunks.shift();
  if (repo.indexOf(prefix) != 0) {
    cb.call(this, 'Malformed message ' + message);
    return;
  }
  repo = repo.slice(prefix.length);

  data = {};

  while (chunks.length) {
    chunk = chunks.shift();
    if (chunk == '') {
      continue;
    }
    keyvalue = chunk.split('=');
    if (keyvalue.length != 2) {
      cb.call(this, 'Malformed message ' + message);
      return;
    }
    data[keyvalue[0]] = keyvalue[1];
  }

  parsed_url = node.url.parse(repo, true);
  if (parsed_url.query.remote != undefined) {
    split_remote = parsed_url.query.remote.split('/');
    host = split_remote.shift();
    repo = '/' + split_remote.join('/');
  } else {
    host = data.host;
  }
  if (host == undefined) {
    cb.call(this, 'remote host unknown!');
    return;
  }

  split_host = host.split(':');
  if (split_host.length == 2) {
    host = split_host[0];
    this.server.port = split_host[1];
  }

  this.server.repo = repo;
  this.server.host = host;

  mylog.log(2, 'proxy to host: ' + host);
  mylog.log(2, 'proxy to repo: ' + repo);

  cb.call(this);
};


/*
  Start upload-pack from proxy to server.
  cb: function (error, server_stream)
*/
GitProxyConnection.prototype.startUploadPack = function (cb) {
  var connect,
    gitproxy = this,
    on_connected;

  mylog.log(2, 'port ' + this.server.port + ' host ' + this.server.host);

  on_connected = function (socket) {
    mylog.log(2, 'connect returned');
    gitproxy.server.stream = new GitStream(socket);
    gitproxy.server.stream.writeMessage(new Buffer(
      'git-upload-pack ' + gitproxy.server.repo + '\x00host='
        + gitproxy.server.host + '\x00'
    ));
    cb.call(this, undefined, gitproxy.server.stream);
  };

  connect = function (cb2) {
    return node.net.connect(gitproxy.server.port, gitproxy.server.host, cb2);
  };

  myutil.robustly({
    label: 'connect to ' + gitproxy.server.host,
    maxtime: 180 * 1000,
    fn: connect,
    fn_on_complete: on_connected,
    fn_on_error: function (ex) {
      mylog.log(2, 'gitstream connect error: ' + ex);
      return 2;
    },
    fn_on_give_up: function (ctx, ex) {
      cb.call(this, ex);
    }
  });

};



GitProxyConnection.prototype.readServerPreamble = function (message, cb) {
  var gitproxy = this,
    matches,
    ref,
    sha,
    send_to_client = message.msgdata,
    split;

  // End of preamble?
  if (message.length == 0) {
    return cb.call(this, undefined, cb);
  }

  // Strip trailing \n if any
  message = message.msgdata;
  message = myutil.chomp(message);

  message = message.toString();

  // First message will have included the capabilities, separated by \n
  split = message.split('\x00');
  if (split.length == 2) {
    send_to_client = message + '\n';
    this.server.caps = split[1].split(' ');
    message = myutil.chomp(split[0]);
  }

  // Expected:
  //  <SHA1> <ref>
  matches = message.match(/^([a-f0-9]{40}) (.+)$/i);
  if (matches == null || matches.length != 3) {
    return cb.call(this, "expected sha/ref, got '" + message + "')");
  }

  ref = matches[2];
  sha = matches[1];
  this.server.refs_by_ref[ref] = sha;
  this.server.refs_by_sha[sha] = ref;
  this.server.refs_by_order.push({ ref: ref, sha: sha });

  this.client.stream.writeMessage(new Buffer(send_to_client));
};

/*
  Read a WANT message from client.
  cb: function (error, want_count)
*/
GitProxyConnection.prototype.readClientWant = function (message, cb) {
  var gitproxy = this,
    cap,
    cmd,
    matches,
    revlistPq,
    sha;

  if (message.length == 0) {
    // All wants are known.
    revlistPq = this.revlistPq;
    delete this.revlistPq;

    if (!revlistPq || revlistPq.empty()) {
      return cb.call(this, undefined, _.size(gitproxy.client.want));
    }
    this.client.stream.pause();
    return revlistPq.once('emptied', function () {
      return cb.call(this, undefined, _.size(gitproxy.client.want));
    });
  }

  message = message.msgdata;
  message = myutil.chomp(message);
  mylog.log(2, 'client message: ' + message);
  message = message.toString();

  matches = message.match(/^want ([a-f0-9]{40})(?: (.+))?$/i);
  if (!matches || (matches.length != 2 && matches.length != 3)) {
    return cb.call(this, "expected 'want <sha1>', got '" + message + "'");
  }

  sha = matches[1];
  if (matches.length == 3 && matches[2]) {
    cap = matches[2].split(' ');
    mylog.log(2, 'client wants caps ' + cap);
    this.client.caps = cap;
  }

  this.client.want[sha] = 1;
  this.want[sha] = 1;

  // check if we have this SHA already
  // FIXME: find a way to do this which doesn't require one
  // process per SHA
  cmd = 'git rev-list --no-walk ' + sha;
  mylog.log(2, 'run: ' + cmd);

  if (!gitproxy.revlistPq) {
    gitproxy.revlistPq = new ProcessQueue();
  }

  (function () {
    var this_sha = sha;
    gitproxy.revlistPq.exec(
      cmd,
      {},
      function (error, stdout, stderr) {
        if (error == null) {
          mylog.log(2, 'git rev-list says we have ' + this_sha);
          delete gitproxy.want[this_sha];
        } else {
          mylog.log(2, 'git rev-list says we do not have ' + this_sha);
        }
      }
    );
  }());
};

/*
  Write appropriate WANT to server.

  cb: function (error, want_wrote_count)
*/
GitProxyConnection.prototype.writeServerWant = function (cb) {
  // TODO: proper capability handling
  var postfix = ' side-band side-band-64k',
    sha,
    count = 0;

  for (sha in this.want) {
    if (this.want.hasOwnProperty(sha)) {
      this.server.stream.writeMessage(new Buffer('want ' + sha + postfix + '\n'));
      postfix = '';
      ++count;
    }
  }
  this.server.stream.writeFlush();

  return cb.call(this, undefined, count);
};

GitProxyConnection.prototype.endWriteServerHave = function (cb, have_count) {
  this.server.stream.writeMessage(new Buffer('done\n'));
  return cb.call(this, undefined, have_count);
};

/*
  Write haves to server.
  cb: function (error, have_count)
*/
GitProxyConnection.prototype.writeServerHave = function (cb) {
  var gitproxy = this,
    read_message,
    rev_list,
    have_count = 0;

  /*
    Currently, this supports only the most basic protocol,
    i.e. neither multi_ack nor multi_ack_detailed are supported.
  */

  rev_list = node.child_process.spawn(
    'git',
    [ 'rev-list', '--glob=refs/persistent/', '--date-order', '--max-count=1024' ]
  );

  rev_list.stdout.on('data', function (data) {
    var have_line,
      i,
      lines = data.toString().split('\n');
    for (i = 0; i < lines.length; ++i) {
      if (!lines[i].length) {
        continue;
      }
      have_line = new Buffer('have ' + lines[i] + '\n');
      gitproxy.server.stream.writeMessage(have_line);
      ++have_count;
    }
  });

  rev_list.stderr.on('data', function (line) {
    mylog.log(1, 'rev-list stderr: ' + line);
  });

  rev_list.on('exit', function () {
    gitproxy.endWriteServerHave(cb, have_count);
  });

  read_message = function (m) {
    var matches,
      str = m.msgdata.toString();

    if (str == 'NAK\n') {
      // NAK: no common object found, keep going.
      gitproxy.server.stream.once('message', read_message);
      return;
    }

    // Should be an ACK
    matches = str.match(/^ACK ([0-9a-fA-F]{40})\n$/);
    if (!matches || matches.length != 2) {
      return cb.call(gitproxy, 'Expected ACK or NAK, got: ' + str);
    }
    mylog.log(2, 'server acked ' + matches[1]);
    rev_list.removeAllListeners('stdout');
    rev_list.kill();
  };
  this.server.stream.once('message', read_message);
};

/*
  Do git index-pack - the process which receives the git data from server
  and stores it in the cache.
  cb: function (error)
*/
GitProxyConnection.prototype.doLocalIndexPack = function (cb) {

  var gitproxy = this,
    git_index_pack,
    index_pack_stderr_remaining,
    prefix,
    client_socket = this.client.stream.socket(),
    conn_id = this.connectionId();

  mylog.log(2, 'spawning git index-pack');

  git_index_pack = node.child_process.spawn(
    'git',
    [ 'index-pack', '-v', '--stdin', '--keep='+conn_id ]
  );
  git_index_pack.stdin.on('error', function (error) {
    return cb.call(this,
      'write to git index-pack: ' + error + "\nStandard error:\n"
        + gitproxy.indexPackStderr);
  });

  this.sidebandTwoFromServerToClient = [];

  prefix = this.server.host + ': ';

  git_index_pack.stdout.on('data', function (d) {
    mylog.log(2, 'git-index-pack stdout: ' + d);
  });

  gitproxy.indexPackStderr = '';
  git_index_pack.stderr.on('data', function (d) {
    var i = 0,
      s,
      split = d.toString().split('\r');

    gitproxy.indexPackStderr += d.toString();

    d = myutil.bufcat(index_pack_stderr_remaining, d);
    while (split.length > 1) {
      s = split.shift();
      s = new Buffer(prefix + s + '\r');
      gitproxy.sidebandTwoFromServerToClient.push(s);
      ++i;
    }
    split = split[0].split('\n');
    while (split.length > 1) {
      s = split.shift();
      s = new Buffer(prefix + s + '\n');
      gitproxy.sidebandTwoFromServerToClient.push(s);
      ++i;
    }
    index_pack_stderr_remaining = split[0];
  });

  git_index_pack.on('exit', function () {
    gitproxy.server.stream.destroySoon();
    return cb.call(this, undefined);
  });

  this.server.stream.on('sideband1', function (message) {
    // sideband 1, demux to index-pack
    git_index_pack.stdin.write(message.sidebanddata);
  });

  this.server.stream.on('sideband2', function (message) {
    // need to prefix every line
    var i,
      s,
      split = message.msgdata.toString().split('\r');

    while (split.length > 1) {
      s = split.shift();
      s = myutil.bufcat(new Buffer(prefix), new Buffer(s + '\r'));
      gitproxy.sidebandTwoFromServerToClient.push(s);
      ++i;
    }
    split = split[0].split('\n');
    while (split.length > 1) {
      s = split.shift();
      s = myutil.bufcat(new Buffer(prefix), new Buffer(s + '\n'));
      gitproxy.sidebandTwoFromServerToClient.push(s);
    }
  });
};

/*
  Returns a unique ID for this connection, safe for usage in filenames
*/
GitProxyConnection.prototype.connectionId = function () {
  var client_socket = this.client.stream.socket();
  return client_socket.remoteAddress + '-' + client_socket.remotePort;
};

GitProxyConnection.prototype.connectionLabel = function () {
  var client_socket, connection_id;

  client_socket = this.client.stream.socket();
  connection_id = client_socket.remoteAddress + ':' + client_socket.remotePort;

  if (this.server && this.server.host) {
    connection_id = node.util.format(
      '%s <-> %s:%d%s',
      connection_id,
      this.server.host,
      this.server.port,
      this.server.repo
    );
  }

  return '[' + connection_id + ']';
};

/*
  Update persistent and in-progress refs (for a request in progress)
*/
GitProxyConnection.prototype.updateRefs = function (cb) {
  var gitproxy = this,
    client_id = this.connectionId(),
    cmd,
    i,
    pq = new ProcessQueue(),
    ref,
    refs,
    persistent_ref,
    server_ref,
    sha;

  for (sha in this.client.want) {
    if (this.client.want.hasOwnProperty(sha)) {
      refs = [];
      server_ref = this.server.refs_by_sha[sha];
      refs.push('refs/in-progress/' + client_id + '/' + server_ref);

      persistent_ref = 'refs/persistent/' + this.server.host + '/' + this.server.repo + '/' + server_ref;
      persistent_ref = persistent_ref.replace(/[^A-Za-z0-9\/\-_\.]/g, '-');
      persistent_ref = persistent_ref.replace(/\/+/g, '/');
      refs.push(persistent_ref);

      for (i = 0; i < refs.length; ++i) {
        ref = refs[i];
        cmd = 'git update-ref --no-deref ' + ref + ' ' + sha;
        mylog.log(3, 'run: ' + cmd);
        pq.exec(cmd);
      }
    }
  }

  pq.once('emptied', function () {
    return cb.call(gitproxy);
  });
};


/*
  Do the git upload-pack from proxy to client
*/
GitProxyConnection.prototype.doLocalUploadPack = function (cb) {
  var gitproxy = this,
    git_upload_pack,
    stdout,
    stdin;

  mylog.log(2, 'spawning git upload-pack');

  git_upload_pack = node.child_process.spawn(
    'git',
    [ 'upload-pack', '.' ]
  );
  git_upload_pack.stdin.on('error', function (error) {
    cb.call(gitproxy, 'write to git upload-pack: ' + error);
  });

  stdout = new GitStream(git_upload_pack.stdout);
  stdin = new GitStream(git_upload_pack.stdin);

  git_upload_pack.stderr.on('data', function (d) {
    mylog.log(2, 'git-upload-pack stderr: ' + d);
  });

  git_upload_pack.on('exit', function () {
    mylog.log(2, 'git-upload-pack finished!');
    gitproxy.client.stream.destroySoon();
    cb.call(gitproxy, undefined);
  });

  stdin.on('error', function (e) {
    mylog.trace(1, 'write to git-upload-pack: ' + e);
  });

  // we don't read from 'message' here, as the upload-pack preamble
  // can be entirely ignored
  stdout.once('flush', function (m) {
    var prefix, postfix, text, want, firstSidebandTwo;
    // send capabilities on first line
    postfix = ' ' + gitproxy.client.caps.join(' ');
    // replay all wants
    for (want in gitproxy.client.want) {
      if (gitproxy.client.want.hasOwnProperty(want)) {
        text = 'want ' + want + postfix;
        stdin.writeMessage(new Buffer(text));
        postfix = '';
      }
    }
    stdin.writeFlush();

    prefix = new Buffer("\x02proxy: ");

    stdout.on('message', function (message) {
      if (message.sideband == 2) {
        return;
      }
      gitproxy.client.stream.write(message.rawdata);
    });

    firstSidebandTwo = true;
    stdout.on('sideband2', function (message) {
      var messageFromServer;
      if (firstSidebandTwo) {
        firstSidebandTwo = false;
        while (gitproxy.sidebandTwoFromServerToClient.length) {
          messageFromServer = gitproxy.sidebandTwoFromServerToClient.shift();
          messageFromServer = myutil.bufcat(new Buffer('\x02'), messageFromServer);
          gitproxy.client.stream.writeMessage(messageFromServer);
        }
      }
      // prefix so the user knows who is outputting this
      gitproxy.client.stream.writeMessage(myutil.bufcat(prefix, message.sidebanddata));
    });

    gitproxy.client.stream.on('message', function (m) {
      stdin.writeMessage(m.msgdata);
    });

    // any saved up data can finally be sent
    gitproxy.client.stream.resume();
  });

};

GitProxyConnection.prototype.fatalError = function (message) {
  mylog.trace(1, 'fatal error: ' + message);
  try {
    this.client.stream.writeMessage(new Buffer('ERR ' + message));
  } catch (e) {
  }
};

/* ================= STATE MACHINE DEFINITION ============================= */
function gitProxyStateObject(fire) {
  var conn,
    conn_id,
    conn_label,
    client_id,
    dumpInfo,
    warn,
    pack_dir = 'objects/pack',
    out = {},
    count = 0,
    cache_stat = CACHE_NO_OBJECTS_REQUESTED;

  // FIXME: much of the time, fire.$event() silently does not work.
  // The reason is unclear.
  // fire.$cb() works, so we use that instead.

  dumpInfo = function (text) {
    mylog.log(0, '  ', conn_label, text);
  };
  warn = function (text) {
    mylog.log(0, '  ', conn_label, 'Warning:', text);
  };

  out.defaults = {
    ignore: [
      'clientStream.flush',
      'clientStream.newListener',
      'serverStream.close',
      'serverStream.flush',
      'serverStream.newListener'
    ],
    actions: {
      'api.dumpInfo': _.bind(dumpInfo, undefined, '(unknown state)'),
      // client may close connection at any time
      'clientStream.end': 'Completed'
    }
  };

  out.states = {

    AwaitingClientChunk1: {
      entry: function (c) {
        conn = new GitProxyConnection(c);
        conn_id = conn.connectionId();
        conn_label = conn.connectionLabel();
        fire.$addToLibrary('conn', conn);
        fire.$regEmitter('clientStream', conn.client.stream, true);
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'waiting for first data from client'),
        'clientStream.message': function (m) {
          fire.conn.handleClientChunk1(m);
        },
        'conn.handleClientChunk1.done': 'ConnectingToServer',
        'conn.handleClientChunk1.err': 'FatalError'
      }
    },

    ConnectingToServer: {
      entry: function () {
        // conn_label is updated because server is now known
        conn_label = conn.connectionLabel();
        fire.conn.startUploadPack();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'connecting to server'),
        'conn.startUploadPack.err': function (ex) {
          conn.fatalError('fatal error while connecting to server: ' + ex);
          return '@error';
        },
        'conn.startUploadPack.done': function (stream) {
          return ['ReadingServerPreamble', stream];
        }
      }
    },

    ReadingServerPreamble: {
      entry: function (stream) {
        fire.$regEmitter('serverStream', stream, true);
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'reading server preamble'),
        'serverStream.message': function (m) {
          fire.conn.readServerPreamble(m);
        },
        'conn.readServerPreamble.done': function () {
          conn.client.stream.writeFlush();
          return 'ReadingClientWant';
        }
      }
    },

    ReadingClientWant: {
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'reading client WANT'),
        'clientStream.message': function (m) {
          fire.conn.readClientWant(m);
        },
        'conn.readClientWant.done': 'WritingServerWant'
      }
    },

    WritingServerWant: {
      entry: function (count) {
        // if client wants at least one object, we start in COLD state.
        // Otherwise we remain in default "no objects requested" state.
        if (count) {
          cache_stat = CACHE_COLD;
        }
        fire.conn.writeServerWant();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'writing server WANT'),
        'conn.writeServerWant.done': function (count) {
          // No want?  Then drop server connection, skip straight to UpdateRefs.
          // This is an entirely hot request (100% from cache)
          if (count == 0) {
            if (cache_stat != CACHE_NO_OBJECTS_REQUESTED) {
              cache_stat = CACHE_HOT;
            }
            conn.server.stream.destroy();
            return 'UpdatingProxyRefs';
          }

          return 'WritingServerHave';
        }
      }
    },

    WritingServerHave: {
      entry: function () {
        fire.conn.writeServerHave();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'negotiating HAVEs with server'),
        'conn.writeServerHave.done': function (have_count) {
          if (have_count) {
            cache_stat = CACHE_WARM;
          }
          return 'ReceivingServerPack';
        }
      }
    },

    ReceivingServerPack: {
      entry: function () {
        fire.conn.doLocalIndexPack();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'receiving git objects from server'),
        'conn.doLocalIndexPack.done': 'UpdatingProxyRefs',
        // these are handled internally
        'serverStream.message': '@ignore',
        'serverStream.sideband1': '@ignore',
        'serverStream.sideband2': '@ignore',
        'serverStream.end': '@ignore',
        'serverStream.close': '@ignore',
        // FIXME! there is a left-over message somewhere.
        'conn.writeServerHave.err': '@ignore',
        'conn.writeServerHave.done': '@ignore'
      }
    },

    UpdatingProxyRefs: {
      entry: function () {
        fire.conn.updateRefs();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'updating refs on proxy'),
        'conn.updateRefs.done': 'SendingPack'
      }
    },

    SendingPack: {
      entry: function () {
        fire.conn.doLocalUploadPack();
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'updating refs on proxy'),
        'conn.doLocalUploadPack.done': 'WaitingClientClose',
        'clientStream.message': '@ignore',
        'clientStream.close': '@defer'
      }
    },

    WaitingClientClose: {
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'waiting for client to close connection'),
        'clientStream.close': 'CleaningKeepFiles'
      }
    },

    CleaningKeepFiles: {
      entry: function () {
        fire.fs.readdir(pack_dir);
        count = 0;
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'cleaning up .keep files'),

        'fs.readdir.done': function (files) {
          var that = this;
          files = _.filter(files, function (file) {
            return file.match(/.keep$/);
          });
          files = _.map(files, function(f) {
            return pack_dir + '/' + f;
          });
          count = files ? files.length : 0;
          _.each(files, function(filename) {
            node.fs.readFile(filename, function (error, data) {
              if (error) {
                return fire.$cb('.err').call(this, error);
              }
              return fire.$cb('readFile.done').call(this, filename, data);
            });
          });

          fire.$cb('checkCounts').call(this);
        },

        'readFile.done': function (filename, data) {
          --count;
          if (data == conn_id + '\n') {
            ++count;
            fire.fs.unlink(filename);
          }
          fire.$cb('checkCounts').call(this);
        },

        'fs.unlink.done': function () {
          --count;
          fire.$cb('checkCounts').call(this);
        },

        'checkCounts': function () {
          if (!count) {
            return 'CleaningRefs';
          }
        },

        '.err': function (error) {
          warn(
            'Problem cleaning up .keep files: ' + error + "\n" +
            'Some stale files may be left behind.'
          );
          return 'CleaningRefs';
        }

      }
    },

    CleaningRefs: {
      entry: function () {
        fire.remove.removeAsync('refs/in-progress/' + conn_id);
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, 'cleaning up refs'),
        'remove.removeAsync.done': function () {
          // after removing that subdirectory, try to remove in-progress
          // as well.  This will succeed iff there are no other ongoing
          // connections.
          fire.fs.rmdir('refs/in-progress');
        },
        'remove.removeAsync.err': function (error) {
          warn(
            'Error removing in-progress refs: ' + error
          );
          return 'Completed';
        },

        'fs.rmdir.err': 'Completed',
        'fs.rmdir.done': 'Completed'
      }
    },

    Completed: {
      entry: function () {
        // Instead of exiting immediately, insert an arbitrary delay,
        // so we keep a temporary record of all recently closed
        // connections.
        setTimeout(fire.$cb('exit'), 10000);
      },
      actions: {
        'api.dumpInfo': _.bind(dumpInfo, undefined, '(finished)'),
        'clientStream.close': '@ignore',
        'exit': function () {
          return ['@exit', cache_stat];
        }
      }
    }

  };

  out.startState = 'AwaitingClientChunk1';
  out.api = ['dumpInfo'];

  return out;
}

function makeNewGitProxyFactory() {
  var igniteLogLevel = 0,
    ngitcachedLogLevel = process.env.NGITCACHED_LOGLEVEL;

  if (ngitcachedLogLevel > 2) {
    igniteLogLevel = 8;
  } else if (ngitcachedLogLevel > 1) {
    igniteLogLevel = 4;
  }

  return new ignite.Factory(
    gitProxyStateObject,
    {
      fs: node.fs,
      remove: _.extend({}, require('remove'))
    },
    {
      // strict mode is nice for testing, but impractical otherwise, since
      // events could potentially be added in new node.js versions without
      // our knowledge
      strict: process.env.NGITCACHED_TEST,
      logLevel: igniteLogLevel
    }
  );
}

/* ============================= exports ================================= */

function GitProxy() {
  this.factory = makeNewGitProxyFactory();
  this.stats = {
    completed: 0,
    in_progress: 0,
    successful: 0,
    error: 0,
    hot: 0,
    warm: 0,
    cold: 0,
    no_objects: 0
  };
}

GitProxy.prototype = {};
GitProxy.prototype.constructor = GitProxy;

GitProxy.prototype.handleConnect = function (c) {
  var sm = this.factory.spawn(c);
  this.recordConnectionInProgress();
  sm.on('error', _.bind(this.recordConnectionComplete, this, REASON_ERROR));
  sm.on('exit', _.bind(this.recordConnectionComplete, this, REASON_EXIT));
};

GitProxy.prototype.recordConnectionInProgress = function () {
  ++this.stats.in_progress;
};

GitProxy.prototype.recordConnectionComplete = function (reason, warmth) {
  --this.stats.in_progress;
  ++this.stats.completed;
  if (reason == REASON_ERROR) {
    ++this.stats.error;
    return;
  }
  ++this.stats.successful;
  if (warmth == CACHE_HOT) {
    ++this.stats.hot;
  } else if (warmth == CACHE_WARM) {
    ++this.stats.warm;
  } else if (warmth == CACHE_COLD) {
    ++this.stats.cold;
  } else {
    ++this.stats.no_objects;
  }
};

GitProxy.prototype.dumpStats = function () {
  var out = node.util.format(
    "========================== Connection statistics: =====================\n"
   +" In progress:              %d\n"
   +" Completed (successful):   %d\n"
   +" Completed (with error):   %d\n"
   +" Hot requests:             %d\n"
   +" Warm requests:            %d\n"
   +" Cold requests:            %d\n"
   +" Requests with no objects: %d",
    this.stats.in_progress,
    this.stats.successful,
    this.stats.error,
    this.stats.hot,
    this.stats.warm,
    this.stats.cold,
    this.stats.no_objects
  );
  mylog.log(0, out);
};

GitProxy.prototype.dumpInfo = function () {
  mylog.log(0, "\n\nngitcached v" + process.env.NGITCACHED_VERSION);
  this.dumpStats();
  if (!this.stats.in_progress) {
    return;
  }
  mylog.log(0,
    '========================== Current Connections: ======================='
  );
  this.factory.broadcast('api.dumpInfo');
};

exports.GitProxy = GitProxy;

// vim: expandtab:ts=2:sw=2
