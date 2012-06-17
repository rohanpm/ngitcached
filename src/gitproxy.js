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
  net: require('net'),
  url: require('url'),
  util: require('util'),
  events: require('events'),
  child_process: require('child_process')
};

var myutil = require('./util.js');
var mylog = require('./log.js');
var GitStream = require('./gitstream.js').GitStream;
var ProcessQueue = require('./processqueue.js').ProcessQueue;

var GIT_PORT = 9418;

function GitProxy(client) {
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

GitProxy.prototype = new node.events.EventEmitter();
GitProxy.prototype.constructor = GitProxy;

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

GitProxy.prototype.onClientSocketError = function (ex) {
  mylog.log(1, "client socket error: '" + ex + "', dropping connection");
  this.client.stream.destroy();
  this.server.stream.destroy();
};

GitProxy.prototype.handleClientChunk1 = function (message) {
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

  mylog.log(2, "First line of git data is: " + node.util.inspect(message));
  message = message.msgdata;

  mylog.log(2, 'Message: ' + message);

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
    mylog.log(1, 'Malformed message ' + message);
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
      mylog.log(1, 'Malformed message ' + message);
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
    this.fatalError('remote host unknown!');
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

  this.startUploadPack();
};


GitProxy.prototype.startUploadPack = function () {
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
    gitproxy.server.stream.once('message', function (m) {
      gitproxy.readServerPreamble(m);
    });
  };

  connect = function (cb) {
    return node.net.connect(gitproxy.server.port, gitproxy.server.host, cb);
  };

  myutil.robustly({
    label: 'connect to ' + gitproxy.server.host,
    maxtime: 180 * 1000,
    fn: connect,
    fn_on_complete: on_connected,
    fn_on_error: function (ex) {
      mylog.log(2, 'gitstream connect error: ' + ex);
      return 2;
    }
  });

};



GitProxy.prototype.readServerPreamble = function (message) {
  var gitproxy = this,
    matches,
    ref,
    sha,
    send_to_client = message.msgdata,
    split;

  // End of preamble?
  if (message.length == 0) {
    this.client.stream.writeFlush();
    this.client.stream.removeAllListeners('message');
    this.client.stream.once('message', function (m) {
      gitproxy.startReadClientWant(m);
    });
    return;
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
    this.fatalError("expected sha/ref, got '" + message + "')");
    return;
  }

  ref = matches[2];
  sha = matches[1];
  this.server.refs_by_ref[ref] = sha;
  this.server.refs_by_sha[sha] = ref;
  this.server.refs_by_order.push({ ref: ref, sha: sha });

  this.client.stream.writeMessage(new Buffer(send_to_client));

  this.server.stream.once('message', function (m) {
    gitproxy.readServerPreamble(m);
  });
};

GitProxy.prototype.startReadClientWant = function (message) {
  this.readingWants = true;
  this.revlistPq = new ProcessQueue();
  return this.readClientWant(message);
};

GitProxy.prototype.readClientWant = function (message) {
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

    this.readingWants = false;
    if (revlistPq.empty()) {
      return this.writeServerWant();
    }
    this.client.stream.pause();
    return revlistPq.once('emptied', function () {
      gitproxy.writeServerWant();
    });
  }

  message = message.msgdata;
  message = myutil.chomp(message);
  mylog.log(2, 'client message: ' + message);
  message = message.toString();

  matches = message.match(/^want ([a-f0-9]{40})(?: (.+))?$/i);
  if (!matches || (matches.length != 2 && matches.length != 3)) {
    return this.fatalError("expected 'want <sha1>', got '" + message + "'");
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

  this.client.stream.once('message', function (m) {
    gitproxy.readClientWant(m);
  });
};

GitProxy.prototype.writeServerWant = function () {
  // TODO: proper capability handling
  var postfix = ' side-band side-band-64k',
    sha,
    wrote_want = false;

  for (sha in this.want) {
    if (this.want.hasOwnProperty(sha)) {
      this.server.stream.writeMessage(new Buffer('want ' + sha + postfix + '\n'));
      postfix = '';
      wrote_want = true;
    }
  }
  this.server.stream.writeFlush();

  if (!wrote_want) {
    this.server.stream.destroySoon();
    return this.updateRefs();
  }

  this.writeServerHave();
};

GitProxy.prototype.endWriteServerHave = function () {
  if (this.endedWriteServerHave) {
    return;
  }
  this.endedWriteServerHave = true;
  this.server.stream.writeMessage(new Buffer('done\n'));
  return this.doLocalIndexPack();
};

GitProxy.prototype.writeServerHave = function () {
  var gitproxy = this,
    rev_list;

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
    }
  });

  rev_list.stderr.on('data', function (line) {
    mylog.log(1, 'rev-list stderr: ' + line);
  });

  rev_list.on('exit', function () {
    gitproxy.server.stream.removeAllListeners('message');
    gitproxy.endWriteServerHave();
  });

  this.server.stream.on('message', function (m) {
    var matches,
      str = m.msgdata.toString();

    if (str == 'NAK\n') {
      // NAK: no common object found, keep going.
      return;
    }

    // Should be an ACK
    matches = str.match(/^ACK ([0-9a-fA-F]{40})\n$/);
    if (!matches || matches.length != 2) {
      return gitproxy.fatalError('Expected ACK or NAK, got: ' + str);
    }
    mylog.log(2, 'server acked ' + matches[1]);
    gitproxy.server.stream.removeAllListeners('message');
    rev_list.removeAllListeners('exit');
    rev_list.kill();
    return gitproxy.endWriteServerHave();
  });
};

GitProxy.prototype.doLocalIndexPack = function () {

  var gitproxy = this,
    git_index_pack,
    index_pack_stderr_remaining,
    prefix;

  mylog.log(2, 'spawning git index-pack');

  git_index_pack = node.child_process.spawn(
    'git',
    [ 'index-pack', '-v', '--stdin', '--keep' ]
  );
  git_index_pack.stdin.on('error', function (error) {
    gitproxy.fatalError(
      'write to git index-pack: ' + error + "\nStandard error:\n"
        + gitproxy.indexPackStderr
    );
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
    gitproxy.updateRefs();
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

GitProxy.prototype.updateRefs = function () {
  var gitproxy = this,
    client_socket = this.client.stream.socket(),
    client_id = client_socket.remoteAddress + '-' + client_socket.remotePort,
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
        mylog.log(2, 'run: ' + cmd);
        pq.exec(cmd);
      }
    }
  }

  mylog.log(2, 'waiting for child processes complete');
  pq.once('emptied', function () {
    gitproxy.doLocalUploadPack();
  });
};


GitProxy.prototype.cleanup = function () {
  var client_socket = this.client.stream.socket(),
    client_id = client_socket.remoteAddress + '-' + client_socket.remotePort;

  node.child_process.spawn(
    'rm',
    ['-rf', '.git/refs/in-progress/' + client_id]
  );
};


GitProxy.prototype.doLocalUploadPack = function () {
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
    gitproxy.fatalError('write to git upload-pack: ' + error);
  });

  stdout = new GitStream(git_upload_pack.stdout);
  stdin = new GitStream(git_upload_pack.stdin);

  git_upload_pack.stderr.on('data', function (d) {
    mylog.log(2, 'git-upload-pack stderr: ' + d);
  });

  git_upload_pack.on('exit', function () {
    mylog.log(2, 'git-upload-pack finished!');
    gitproxy.client.stream.destroySoon();
    gitproxy.cleanup();
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

GitProxy.prototype.fatalError = function (message) {
  mylog.trace(1, 'fatal error: ' + message);
  try {
    this.client.stream.writeMessage(new Buffer('ERR ' + message));
  } catch (e) {
  }
};

/*
  handleConnection is the entry-point to the proxy.
  
    c:  connection (net.Socket object)

*/
exports.handleConnection = function (c) {
  var proxy = new GitProxy(c);
  proxy.client.stream.once('message', function (m) {
    proxy.handleClientChunk1(m);
  });
};

// vim: expandtab:ts=2:sw=2
