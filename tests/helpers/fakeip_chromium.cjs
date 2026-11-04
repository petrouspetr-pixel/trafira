// Real Chromium classification of both ranges; no Internet or user profile.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

async function main() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'trafira-chromium-'));
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html', 'X-Trafira-Test-Address': req.headers.host });
    res.end('<html><head><link rel="icon" href="data:,"></head><body>Address-space test</body></html>');
  });
  await new Promise(resolve => server.listen(0, '::', resolve));
  const chrome = spawn(process.env.CHROME_BIN || 'google-chrome', [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
    '--no-proxy-server', '--remote-debugging-port=0', '--user-data-dir=' + profile,
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'], detached: true });
  let socket;
  try {
    const endpoint = await new Promise((resolve, reject) => {
      let logs = '';
      const deadline = setTimeout(() => reject(Error('Chrome startup timeout: ' + logs)), 15000);
      chrome.on('error', reject);
      chrome.on('exit', code => reject(Error('Chrome exited: ' + code + ' ' + logs)));
      chrome.stderr.on('data', chunk => {
        logs += chunk;
        const match = logs.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (match) { clearTimeout(deadline); resolve(match[1]); }
      });
    });
    const base = new URL(endpoint);
    const target = await fetch(`http://${base.host}/json/new?about:blank`, { method: 'PUT' }).then(r => r.json());
    socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    let nextId = 0;
    const pending = new Map(), events = [];
    socket.onmessage = event => {
      const value = JSON.parse(event.data);
      if (value.id) {
        const callback = pending.get(value.id);
        pending.delete(value.id);
        if (value.error) callback?.reject(Error(JSON.stringify(value.error)));
        else callback?.resolve(value.result);
      } else events.push(value);
    };
    const call = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
    await call('Network.enable');
    await call('Page.enable');
    const results = {};
    for (const address of ['fc00::123', '2001:2::123']) {
      await call('Page.navigate', { url: `http://[${address}]:${server.address().port}/` });
      const deadline = Date.now() + 10000;
      let info;
      while (Date.now() < deadline) {
        info = events.find(e => e.method === 'Network.responseReceivedExtraInfo' &&
          Object.entries(e.params.headers || {}).some(([name, value]) =>
            name.toLowerCase() === 'x-trafira-test-address' && value.includes(address)));
        if (info) break;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      assert(info, `Missing actual Chromium response metadata for ${address}`);
      results[address] = info.params.resourceIPAddressSpace;
    }
    assert.equal(results['fc00::123'], 'Local', 'old ULA range is classified as local-network access');
    assert.equal(results['2001:2::123'], 'Public', 'new benchmark range does not require local-network access');
    console.log('Chromium actual address-space classification:', JSON.stringify(results));
  } finally {
    socket?.close();
    chrome.kill('SIGTERM');
    await new Promise(resolve => chrome.exitCode !== null ? resolve() : chrome.once('exit', resolve));
    // Renderer/utility children may briefly outlive the browser and still write
    // their profile. This process group belongs only to this isolated test.
    try { process.kill(-chrome.pid, 'SIGTERM'); } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
