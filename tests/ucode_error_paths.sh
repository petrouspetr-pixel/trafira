#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Exercise real function bodies in their original declaration order, with only
# filesystem/process dependencies replaced. No router services are touched.
node - "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR" <<'NODE'
const fs = require('fs');
const [lib, dir] = process.argv.slice(2);
const common = `let as_string = v => v == null ? "" : "" + v;
let calls = [];
let command_success_from_args = args => { push(calls, args[0]); return true; };
let lock_dir_write_owner = (path, pid) => false;
let pid_alive = pid => false;
let first_line_value = path => "";
function assert(ok) { if (!ok) { warn("assertion failed\\n"); exit(1); } }
`;
function test(name, file, names, setup, body) {
  const source = fs.readFileSync(`${lib}/${file}`, 'utf8');
  const functions = names.map(name => {
    const start = source.indexOf(`function ${name}(`);
    if (start < 0) throw new Error(`Missing ${name}`);
    const end = source.indexOf('\n}', start) + 2;
    return {start, code:source.slice(start,end)};
  }).sort((a,b) => a.start-b.start);
  fs.writeFileSync(`${dir}/${name}.uc`, common+setup+'\n'+functions.map(f=>f.code).join('\n')+'\n'+body);
}
for (const file of ['service/initd.uc','service/state.uc']) {
  test(file.replaceAll('/','-'), file, ['acquire_runtime_dir_lock','release_runtime_dir_lock'], '',
    'assert(acquire_runtime_dir_lock("/fixture/lock", "123") === false); assert(index(calls, "rmdir") >= 0);');
}
test('ui', 'service/ui.uc', ['acquire_dir_lock','release_dir_lock'], `
let current_pid = () => "123";
let job_pid_valid = pid => true;
let write_file = (path, data) => false;
let remove_file = path => true;
let first_line = path => "";
let pid_running = pid => false;
let fs = {stat: path => null};
let now_seconds = () => 0;
`, 'assert(acquire_dir_lock("/fixture/lock") === false); assert(index(calls, "rmdir") >= 0);');
test('owner', 'service/initd.uc', ['begin_external_service_action','owner_pid_value'], `
const UI_UC = "/fixture/ui";
let getenv = name => null;
let file_exists = path => true;
let module_output = (path, args) => "job";
let command_output_from_args = args => "123";
let module_status = (path, args) => { assert(args[2] == "123"); return 0; };
`, 'assert(begin_external_service_action("reload", "test", "") == "job");');
test('tls', 'server/service.uc', ['server_prepare_tls_defaults','safe_filename_string'], `
let config_get = (section, key, fallback) => fallback;
let server_default_set_option = (section, key, value) => null;
let server_set_option = (section, key, value) => { push(calls, value); };
let valid_file_path = path => true;
let fatal = message => { warn(message); exit(1); };
let regex_matches = (value, pattern) => match(value, regexp(pattern)) != null;
let shell_quote = value => value;
let run = command => true;
let log = (message, level) => null;
let server_generate_tls_keypair_files = (name, cert, key) => true;
`, 'server_prepare_tls_defaults("test/name", "vless", "tls"); assert(index(calls, "/etc/trafira/server-certs/test_name.crt") >= 0);');
NODE
failed=0
for test in "$WORK_DIR/"*.uc; do
  ucode "$test" || failed=1
done
[ "$failed" -eq 0 ]
printf 'ucode cleanup, action owner and TLS default paths passed\n'
