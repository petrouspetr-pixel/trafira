const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../trafira/files/usr/lib/routing/list_download.uc'), 'utf8');
function body(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
// Keep the production download algorithm; only fs pipe/file boundaries are
// modeled. Latin-1 strings preserve byte lengths and embedded NULs in Node.
function run(bodyBytes, options = {}) {
  const target = '/lists/current', temporary = target + '.download.1.2';
  const files = new Map([[target, 'prior-valid-list']]);
  const stream = bodyBytes + (options.trailer ?? '200');
  let position = 0, peak = 0, error = null, pipeClosed = false, outputClosed = false;
  const context = {
    clock: () => [1, 2], sprintf: (_format, p, a, b) => `${p}.download.${a}.${b}`, quote: x => x,
    join: (by, values) => values.join(by), map: (a, fn) => a.map(fn),
    min: Math.min, max: Math.max, length: x => x.length,
    substr: (s, start, count) => count === undefined ? s.slice(start) : s.slice(start, start + count),
    match: (s, re) => s.match(re), int: Number,
    fs: {
      open: name => {
        if (options.openFailure) return null;
        files.set(name, '');
        return {
          write: data => {
            const written = options.shortWrite ? Math.max(0, data.length - 1) : data.length;
            files.set(name, files.get(name) + data.slice(0, written));
            peak = Math.max(peak, files.get(name).length);
            return written;
          },
          close: () => { outputClosed = true; return !options.closeFailure; }
        };
      },
      popen: () => options.pipeFailure ? null : {
        read: maximum => {
          if (options.readFailure) { error = 'I/O error'; return null; }
          if (position === stream.length) return null;
          const count = Math.min(maximum, options.chunkBytes || 65536, stream.length - position);
          const result = stream.slice(position, position + count); position += count;
          return result;
        },
        close: () => { pipeClosed = true; return options.curlCode || 0; }
      },
      error: () => { const value = error; error = null; return value; },
      lstat: name => files.has(name) ? { type: 'file', size: files.get(name).length } : null,
      rename: (from, to) => {
        if (options.renameFailure) return false;
        files.set(to, files.get(from)); files.delete(from); return true;
      },
      unlink: name => files.delete(name)
    }
  };
  vm.createContext(context); vm.runInContext(body('download'), context);
  const result = context.download(['curl', '--write-out', '%{http_code}', 'fixture-url'], target, 1024);
  assert.equal(files.has(temporary), false, 'private staging must be removed');
  assert.equal(peak <= 1024, true, 'staged body must remain within the application cap');
  if (!options.openFailure) assert(outputClosed, 'close output even after failure');
  if (!options.openFailure && !options.pipeFailure) assert(pipeClosed, 'close pipe even after failure');
  return { result, bytes: files.get(target), position };
}
const binary = Buffer.from([0, 255, 128, 10, 13, 50, 48, 48, 0, 49]).toString('latin1');
for (const chunkBytes of [1, 2, 3, 4, 65536]) {
  const { result, bytes } = run(binary, { chunkBytes });
  assert.equal(result.code, 0); assert.equal(result.http_status, 200);
  assert.equal(bytes, binary, `binary payload/trailer boundaries, chunk=${chunkBytes}`);
}
assert.equal(run('x'.repeat(1024), { chunkBytes: 3 }).bytes.length, 1024, 'exact cap accepted');
for (const chunkBytes of [1, 3, 65536]) {
  const { result, bytes, position } = run('x'.repeat(1025), { chunkBytes });
  assert.equal(result.code, 63, 'cap+1 rejected independently of curl');
  assert.equal(bytes, 'prior-valid-list');
  assert(position <= 1028, 'stop reading at cap plus three-byte trailer and one overflow byte');
}
for (const [label, options, expectedCode] of [
  ['curl failure', { curlCode: 7 }, 7],
  ['encoded curl failure', { curlCode: 7 * 256 }, 7],
  ['short write', { shortWrite: true }, 23],
  ['close failure', { closeFailure: true }, 23],
  ['rename failure', { renameFailure: true }, 23],
  ['open failure', { openFailure: true }, 23],
  ['pipe failure', { pipeFailure: true }, 23],
  ['read failure', { readFailure: true }, 23],
  ['missing HTTP trailer', { trailer: '' }, 23],
  ['invalid HTTP trailer', { trailer: '000' }, 23],
]) {
  const { result, bytes } = run(binary, options);
  assert.equal(result.code, expectedCode, label);
  assert.equal(bytes, 'prior-valid-list', `${label}: preserve previous target`);
}
console.log('list download binary, size boundary and I/O failure checks passed');
