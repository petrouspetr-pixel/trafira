const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const http = require('node:http');
const { createHash } = require('node:crypto');
const { waitForDevTools, stopChrome, fetchJSON, openCDP } = require('./chromium_lifecycle.cjs');

async function fixture(t, mode) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'chromium-lifecycle-'));
  const chrome = spawn(process.execPath, ['-e', `
    const fs = require('node:fs'), http = require('node:http');
    const mode = process.argv[1], profile = process.argv[2];
    if (mode === 'exit') { process.stderr.write('fixture fatal diagnostic'); process.exit(23); }
    if (mode === 'stubborn') {
      process.on('SIGTERM', () => {});
      fs.writeFileSync(profile + '/ready', 'ready');
      setInterval(() => {}, 1000);
    }
    else if (mode === 'hang') { process.stderr.write('x'.repeat(20000) + ' diagnostic-tail'); setInterval(() => {}, 1000); }
    else {
      let hits = 0;
      const server = http.createServer((req, res) => {
        if (mode === 'http-hang') return;
        if (mode === 'delayed' && ++hits < 3) { res.writeHead(503); return res.end('starting'); }
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({ webSocketDebuggerUrl: 'ws://127.0.0.1:' + server.address().port + '/devtools/browser/fixture' }));
      }).listen(0, '127.0.0.1', () => {
        const port = server.address().port;
        if (mode !== 'stderr') fs.writeFileSync(profile + '/DevToolsActivePort', port + '\\n/devtools/browser/fixture\\n');
        if (mode === 'stderr') process.stderr.write('DevTools listening on ws://127.0.0.1:' + port + '/devtools/browser/fixture\\n');
      });
    }
  `, mode, profile], { stdio: ['ignore', 'ignore', 'pipe'], detached: process.platform !== 'win32' });
  t.after(async () => {
    if (chrome.exitCode === null && chrome.signalCode === null) {
      chrome.kill('SIGKILL');
      await once(chrome, 'exit');
    }
    fs.rmSync(profile, { recursive: true, force: true });
  });
  return { chrome, profile };
}

async function waitFile(filename) {
  const deadline = Date.now() + 2000;
  while (!fs.existsSync(filename)) {
    if (Date.now() >= deadline) throw Error('Fixture did not create ' + filename);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test('discovers a live DevTools endpoint from its profile without stderr', async t => {
  const { chrome, profile } = await fixture(t, 'file');
  assert.match(await waitForDevTools(chrome, profile, { timeoutMs: 1500 }), /\/devtools\/browser\/fixture$/);
});

test('waits for endpoint readiness after the discovery file appears', async t => {
  const { chrome, profile } = await fixture(t, 'delayed');
  assert.match(await waitForDevTools(chrome, profile, { timeoutMs: 1500 }), /\/devtools\/browser\/fixture$/);
});

test('also verifies a live endpoint announced only on stderr', async t => {
  const { chrome, profile } = await fixture(t, 'stderr');
  assert.match(await waitForDevTools(chrome, profile, { timeoutMs: 1500 }), /\/devtools\/browser\/fixture$/);
});

test('times out when a discovered DevTools endpoint never responds', async t => {
  const { chrome, profile } = await fixture(t, 'http-hang');
  const started = Date.now();
  await assert.rejects(waitForDevTools(chrome, profile, { timeoutMs: 400 }), /startup timeout.*probing/);
  assert(Date.now() - started < 1500);
});

test('keeps startup failure diagnostic bounded and includes the log tail', async t => {
  const { chrome, profile } = await fixture(t, 'hang');
  await assert.rejects(waitForDevTools(chrome, profile, { timeoutMs: 400 }), error => {
    assert.match(error.message, /startup timeout/);
    assert.match(error.message, /diagnostic-tail/);
    assert(error.message.length < 9000);
    return true;
  });
});

test('reports early Chrome exit with status and stderr', async t => {
  const { chrome, profile } = await fixture(t, 'exit');
  await assert.rejects(waitForDevTools(chrome, profile, { timeoutMs: 1500 }), /exited.*23.*fixture fatal diagnostic/);
});

test('reports a missing executable and cleanup handles an unspawned child', async () => {
  const chrome = spawn(path.join(os.tmpdir(), 'trafira-missing-chrome-' + process.pid), [], { stdio: ['ignore', 'ignore', 'pipe'] });
  await assert.rejects(waitForDevTools(chrome, os.tmpdir(), { timeoutMs: 1500 }), /spawn failed.*ENOENT/);
  await stopChrome(chrome);
});

test('bounds a DevTools HTTP request that never responds', async t => {
  const { chrome, profile } = await fixture(t, 'http-hang');
  await waitFile(path.join(profile, 'DevToolsActivePort'));
  const port = fs.readFileSync(path.join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0];
  await assert.rejects(fetchJSON(`http://127.0.0.1:${port}/json/version`, { timeoutMs: 100 }), /timeout/);
});

test('termination finishes for a live child process', async t => {
  const { chrome } = await fixture(t, 'hang');
  await stopChrome(chrome, { graceMs: 100, killMs: 1000 });
  assert(chrome.exitCode !== null || chrome.signalCode !== null);
});

test('escalates TERM to KILL when an isolated process ignores TERM', { skip: process.platform === 'win32' }, async t => {
  const { chrome, profile } = await fixture(t, 'stubborn');
  await waitFile(path.join(profile, 'ready'));
  await stopChrome(chrome, { graceMs: 100, killMs: 1000 });
  assert.equal(chrome.signalCode, 'SIGKILL');
});

test('bounds a WebSocket handshake that never completes', async t => {
  const server = http.createServer();
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.on('upgrade', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { for (const socket of sockets) socket.destroy(); server.close(); });
  await assert.rejects(openCDP(`ws://127.0.0.1:${server.address().port}`, { timeoutMs: 100 }), /timeout/);
});

test('bounds unanswered CDP commands and rejects pending calls on close', async t => {
  const server = http.createServer();
  let peer;
  server.on('upgrade', (req, socket) => {
    peer = socket;
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { peer?.destroy(); server.close(); });
  const cdp = await openCDP(`ws://127.0.0.1:${server.address().port}`, { timeoutMs: 200 });
  t.after(() => cdp.close());
  await assert.rejects(cdp.call('Network.enable'), /Network.enable.*timeout/);
  const pending = cdp.call('Page.enable');
  peer.destroy();
  await assert.rejects(pending, /closed|WebSocket error/);
});
