// Real Chromium classification of both ranges; no Internet or user profile.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { waitForDevTools, fetchJSON, openCDP, stopChrome } = require('./chromium_lifecycle.cjs');

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
    const endpoint = await waitForDevTools(chrome, profile);
    const base = new URL(endpoint);
    const target = await fetchJSON(`http://${base.host}/json/new?about:blank`, { method: 'PUT' });
    socket = await openCDP(target.webSocketDebuggerUrl);
    const { call, events } = socket;
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
    try { await stopChrome(chrome); }
    finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    }
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
