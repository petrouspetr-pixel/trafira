const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '../../install.sh'), 'utf8');
function body(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n}', start) + 2).replaceAll('for (let arg in ', 'for (let arg of ');
}
const pidfile = '/run/trafira/start-retry.pid', script = '/usr/lib/trafira/service/initd.uc';
const init = '/etc/init.d/trafira';
const owner = { version: 1, role: 'wan', pid: '123', ticks: '450', group: '123', session: '123', token: '12345678-1234-1234-1234-123456789abc' };
const modern = ['/usr/bin/ucode', '-L', '/usr/lib/trafira', script, 'scheduled-start-retry-worker', pidfile, '10', '7', init, '400'];
function run(record, args = modern, ticks = '450', reuseAtKill = false) {
  const data = new Map([[pidfile, '123\n'], ['/proc/123/cmdline', args.join('\0') + '\0'],
    ['/proc/123/stat', '123 (ucode) S ' + ['1', ...Array(17).fill('0'), ticks].join(' ')]]);
  if (record !== null) data.set(pidfile + '.owner.json', typeof record === 'string' ? record : JSON.stringify(record));
  const killed = [], removed = [];
  const context = {
    INSTALLER_START_RETRY_PID_FILE: pidfile, INSTALLER_START_RETRY_FILE: '/run/trafira/start.retry',
    INSTALLER_TRAFIRA_INIT: init, INSTALLER_TRAFIRA_LIB: '/usr/lib/trafira', INSTALLER_DEADLINE_HELPER: '/tmp/deadline',
    as_string: x => x == null ? '' : String(x), trim: x => x.trim(), match: (s, r) => s.match(r),
    words: s => s.trim().split(/\s+/), length: x => x.length, split: (s, by) => s.split(by), push: (a, v) => a.push(v),
    index: (s, v) => s.indexOf(v), type: x => typeof x, json: JSON.parse,
    read_text_file: p => data.get(p) || '', unlink_file: p => { removed.push(p); data.delete(p); },
    command_from_args: JSON.stringify, normalize_status: x => x,
    system: command => { killed.push(JSON.parse(command.split(' >/dev/null')[0])); return 0; }
  };
  const names = ['installer_process_starttime', 'installer_process_args', 'installer_args_have_exact',
    'installer_args_contain', 'installer_kill_process_tree', 'installer_cancel_stale_start_retry'];
  // New helper is included when testing fixed sources; baseline remains runnable.
  if (source.includes('function installer_retry_owner_starttime(')) names.splice(-1, 0, 'installer_retry_owner_starttime');
  vm.createContext(context); vm.runInContext(names.map(body).join('\n'), context);
  if (reuseAtKill) {
    const original = context.installer_process_starttime;
    let reads = 0;
    context.installer_process_starttime = pid => ++reads > 1 ? '999' : original(pid);
  }
  context.installer_cancel_stale_start_retry();
  return { killed, removed };
}
{
  const result = run(owner);
  assert.deepEqual(result.killed, [['/tmp/deadline', 'kill-tree', '123', '450']], 'modern verified worker must be cancelled');
  assert(result.removed.includes(pidfile + '.owner.json'), 'clean modern owner record');
}
for (const [label, record, args, ticks, reuse] of [
  ['numeric foreign', null, ['/usr/bin/sleep', '100'], '450'],
  ['missing owner', null, modern, '450'],
  ['malformed owner', '{', modern, '450'],
  ['null owner', 'null', modern, '450'],
  ['wrong version', { ...owner, version: 2 }, modern, '450'],
  ['wrong role', { ...owner, role: 'subscription' }, modern, '450'],
  ['wrong pid', { ...owner, pid: '124' }, modern, '450'],
  ['wrong group', { ...owner, group: '124' }, modern, '450'],
  ['wrong session', { ...owner, session: '124' }, modern, '450'],
  ['wrong token', { ...owner, token: '' }, modern, '450'],
  ['reused pid', owner, modern, '999'],
  ['wrong script', owner, modern.map(x => x === script ? script + '.foreign' : x), '450'],
  ['wrong mode', owner, modern.map(x => x === 'scheduled-start-retry-worker' ? 'other-worker' : x), '450'],
  ['wrong init', owner, modern.map(x => x === init ? init + '-foreign' : x), '450'],
  ['wrong pid path', owner, modern.map(x => x === pidfile ? pidfile + '-foreign' : x), '450'],
  ['reused before kill', owner, modern, '450', true],
]) {
  const result = run(record, args, ticks, reuse);
  assert.equal(result.killed.length, 0, `${label}: must not signal`);
  assert(result.removed.includes(pidfile + '.owner.json'), `${label}: clean stale sidecar`);
}
assert.equal(run(null, ['/bin/sh', '-c', `${init} retry_start_on_wan_up`]).killed.length, 1, 'legacy full command remains supported');
assert.equal(run(null, ['/bin/sh', '-c', `${init} status`]).killed.length, 0, 'legacy action guard remains required');
console.log('installer retry owner compatibility checks passed');
