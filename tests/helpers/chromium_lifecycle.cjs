// Lifecycle support for the isolated Chromium integration test only.
const fs = require('node:fs/promises');
const path = require('node:path');

async function fetchJSON(url, { timeoutMs = 5000, ...options } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    if (!response.ok) throw Error(`HTTP ${response.status}`);
    return await response.json();
  } catch (error) {
    throw Error(`${url}: ${controller.signal.aborted ? 'HTTP timeout' : error.message}`);
  } finally { clearTimeout(timer); }
}

// Cold CI starts have announced DevTools near the previous 15s deadline while
// /json/version was still unavailable. Continue probing within one 30s budget.
function waitForDevTools(chrome, profile, { timeoutMs = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    let logs = '', advertised, lastProbe = 'endpoint not discovered', settled = false, poll;
    const expires = Date.now() + timeoutMs;
    const finish = (error, endpoint) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      clearTimeout(poll);
      chrome.off('error', onError);
      chrome.off('exit', onExit);
      // Keep draining stderr through cleanup, retaining only the bounded tail.
      if (error) reject(Error(`${error}; ${lastProbe}; stderr tail: ${logs}`));
      else resolve(endpoint);
    };
    const onError = error => finish(`Chrome spawn failed: ${error.message}`);
    const onExit = (code, signal) => finish(`Chrome exited: code=${code} signal=${signal}`);
    const onData = chunk => {
      const text = logs + chunk.toString();
      const match = text.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) advertised = match[1];
      logs = text.slice(-8192);
    };
    const deadline = setTimeout(() => finish(`Chrome startup timeout after ${timeoutMs}ms`), timeoutMs);
    chrome.on('error', onError);
    chrome.on('exit', onExit);
    chrome.stderr.on('data', onData);
    chrome.once('close', () => chrome.stderr.off('data', onData));
    if (chrome.exitCode !== null || chrome.signalCode !== null) return onExit(chrome.exitCode, chrome.signalCode);
    const probe = async () => {
      try {
        let endpoint = advertised;
        if (!endpoint) {
          const [port, route] = (await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/);
          if (!/^\d+$/.test(port) || !route?.startsWith('/devtools/browser/')) throw Error('incomplete DevToolsActivePort');
          endpoint = `ws://127.0.0.1:${port}${route}`;
        }
        const base = new URL(endpoint);
        lastProbe = `probing ${base.host}/json/version`;
        const version = await fetchJSON(`http://${base.host}/json/version`, { timeoutMs: Math.max(1, Math.min(500, expires - Date.now())) });
        if (version.webSocketDebuggerUrl !== endpoint) throw Error('DevTools endpoint mismatch');
        finish(null, endpoint);
      } catch (error) { lastProbe = error.message; }
      if (!settled) poll = setTimeout(probe, 50);
    };
    probe();
  });
}

function openCDP(endpoint, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint), pending = new Map(), events = [];
    let nextId = 0, opened = false, failure;
    const fail = error => {
      failure = error;
      clearTimeout(handshake);
      for (const task of pending.values()) { clearTimeout(task.timer); task.reject(error); }
      pending.clear();
      if (!opened) reject(error);
    };
    const handshake = setTimeout(() => { fail(Error('CDP WebSocket open timeout')); socket.close(); }, timeoutMs);
    socket.onerror = () => fail(Error('CDP WebSocket error'));
    socket.onclose = () => fail(Error('CDP WebSocket closed'));
    socket.onmessage = event => {
      let value;
      try { value = JSON.parse(event.data); } catch { fail(Error('Invalid CDP JSON')); socket.close(); return; }
      if (value.id) {
        const task = pending.get(value.id);
        if (!task) return;
        pending.delete(value.id);
        clearTimeout(task.timer);
        if (value.error) task.reject(Error(JSON.stringify(value.error)));
        else task.resolve(value.result);
      } else if (value.method === 'Network.responseReceivedExtraInfo') {
        events.push(value);
        if (events.length > 256) events.shift();
      }
    };
    socket.onopen = () => {
      opened = true;
      clearTimeout(handshake);
      resolve({ events, close: () => { fail(Error('CDP WebSocket closed')); socket.close(); },
        call: (method, params = {}) => new Promise((resolveCall, rejectCall) => {
          if (failure) return rejectCall(failure);
          const id = ++nextId;
          const timer = setTimeout(() => { pending.delete(id); rejectCall(Error(`CDP ${method} timeout after ${timeoutMs}ms`)); }, timeoutMs);
          pending.set(id, { resolve: resolveCall, reject: rejectCall, timer });
          try { socket.send(JSON.stringify({ id, method, params })); }
          catch (error) { clearTimeout(timer); pending.delete(id); rejectCall(error); }
        }),
      });
    };
  });
}

async function stopChrome(chrome, { graceMs = 2000, killMs = 2000 } = {}) {
  if (!chrome.pid) return;
  const exited = () => chrome.exitCode !== null || chrome.signalCode !== null;
  const signal = name => {
    try {
      // Detached group is created only for this isolated test profile.
      if (process.platform !== 'win32') process.kill(-chrome.pid, name);
      else if (!exited()) chrome.kill(name);
    } catch (error) { if (error.code !== 'ESRCH') throw error; }
  };
  const waitExit = ms => new Promise(resolve => {
    if (exited()) return resolve(true);
    const done = () => { clearTimeout(timer); chrome.off('exit', done); resolve(exited()); };
    const timer = setTimeout(done, ms);
    chrome.once('exit', done);
  });
  signal('SIGTERM');
  await waitExit(graceMs);
  // Include renderer/utility children even if the browser has already exited.
  signal('SIGKILL');
  if (!await waitExit(killMs)) throw Error('Chrome cleanup timeout after SIGKILL');
}
module.exports = { waitForDevTools, fetchJSON, openCDP, stopChrome };
