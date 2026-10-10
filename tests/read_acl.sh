#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const assert = require('assert'), fs = require('fs'), vm = require('vm');
const root = process.argv[2];
const acl = JSON.parse(fs.readFileSync(root + '/luci-app-trafira/root/usr/share/rpcd/acl.d/luci-app-trafira.json'))['luci-app-trafira'];
for (const command of ['/usr/bin/trafira', '/etc/init.d/trafira', '/usr/bin/trafira-config']) {
  assert(!acl.read.file[command], `read role must not execute ${command}`);
  assert(acl.write.file[command].includes('exec'));
}
assert(acl.read.file['/usr/bin/trafira-read'].includes('exec'));
const source = fs.readFileSync(root + '/trafira/files/usr/bin/trafira-read', 'utf8').replace(/^#![^\n]*\n/, '');
function run(args) {
  const calls = []; let code;
  const context = {
    ARGV: args, length: value => value.length, index: (array, value) => array.indexOf(value),
    type: value => value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value,
    json: JSON.parse, replace: (text, pattern, value) => text.replace(pattern, value),
    join: (separator, values) => values.join(separator), push: (values, value) => values.push(value),
    system: command => { calls.push(command); return 0; }, print() {},
    exit: value => { code = value; throw 'EXIT'; }
  };
  try { vm.runInNewContext(source, context); } catch (error) { if (error !== 'EXIT') throw error; }
  return { calls, code };
}
for (const args of [
  ['get_status'], ['route_explain', '{}'], ['show_version'], ['global_check', 'masked'],
  ['clash_api', 'get_proxies'], ['clash_api', 'get_proxy_latencies', '["node"]', '5000'],
  ['profile_action', '{"action":"list"}'], ['profile_action', '{"action":"preview","id":"one"}'],
  ['core_action', '{"action":"catalog"}'], ['core_action', '{"action":"status"}'],
  ['gaming_preset_action', '{"action":"preview_remove"}']
]) {
  const result = run(args);
  assert.strictEqual(result.code, 0, `allowed ${args}`);
  assert.strictEqual(result.calls.length, 1);
}
for (const args of [
  [], ['stop'], ['restart'], ['uninstall'], ['package_prerm', 'remove'], ['component_action', 'trafira', 'install'],
  ['component_action_async', 'sing_box', 'install'], ['get_status', 'stop'],
  ['clash_api', 'set_group_proxy', 'group', 'node'], ['clash_api', 'close_all_connections'],
  ['clash_api', 'get_proxy_latencies', '[]', '5000', '/etc/config/trafira'],
  ['profile_action', '{"action":"apply"}'], ['core_action', '{"action":"install"}'],
  ['profile_action', '{"action":"export_begin","id":"home"}'],
  ['profile_action', '{"action":"export_read","id":"transfer","offset":0}'],
  ['core_action', '{"action":"unpin"}'], ['gaming_preset_action', '{"action":"remove"}'],
  ['core_action', 'not-json'], ['core_action', '{"action":"catalog"}', 'install']
]) {
  const result = run(args);
  assert.notStrictEqual(result.code, 0, `denied ${args}`);
  assert.deepStrictEqual(result.calls, [], 'denied requests must never reach the privileged dispatcher');
}
const quoted = run(['route_explain', "a'; touch /tmp/acl-bypass; '"]);
assert(quoted.calls[0].includes("'a'\\''; touch /tmp/acl-bypass; '\\'''"), 'arguments remain quoted');
for (const file of ['/build.sh', '/trafira/Makefile']) {
  assert(fs.readFileSync(root + file, 'utf8').includes('trafira-read'), `dispatcher packaged by ${file}`);
}
console.log('Read ACL and dispatcher isolation checks passed');
NODE
if command -v ucode >/dev/null 2>&1; then
  ucode -c -o /dev/null "$ROOT_DIR/trafira/files/usr/bin/trafira-read"
  ucode -S -c -o /dev/null "$ROOT_DIR/trafira/files/usr/bin/trafira-read"
  if ucode "$ROOT_DIR/trafira/files/usr/bin/trafira-read" stop; then
    echo 'Native read dispatcher accepted a mutating action' >&2
    exit 1
  fi
fi
