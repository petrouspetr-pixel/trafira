#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" "$WORK_DIR" <<'NODE'
const fs = require('fs');
const [file, dir] = process.argv.slice(2);
const source = fs.readFileSync(file, 'utf8');
function extract(name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw Error(`Missing function ${name}`);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
// Exercise the old public rollback entry point, including a repository outage.
fs.writeFileSync(`${dir}/restore.uc`, `
let network = 0;
let installed = "";
let rollback_package = { name: "sing-box-tiny", version: "1.11.9-r1", path: "/stage/old.ipk" };
let rollback_package_files = [ "/stage/dependency.ipk", "/stage/old.ipk" ];
let available_package_version = name => { network++; return "1.12.0-r1"; };
let replace_sing_box_package_variant = (name, conflict, version) => { network++; return false; };
let restore_sing_box_extended_package_variant = () => { network++; return false; };
let sing_box_variant_is_package_managed = v => v == "tiny" || v == "stable" || v == "extended";
let prepare_sing_box_package_service_install = () => true;
let pkg_remove_sing_box_conflict = name => true;
let remove_managed_sing_box_service_script = () => true;
let remove_file = path => true;
let file_nonempty = path => true;
let installed_package_version = name => installed;
let pkg_install_rollback_files = files => { installed = rollback_package.version; return length(files) == 2; };
function assert(ok) { if (!ok) { warn("Offline exact-version rollback failed\\n"); exit(1); } }
${extract('restore_sing_box_package_variant')}
for (let variant in [ "tiny", "stable", "extended" ]) {
  rollback_package.name = variant == "tiny" ? "sing-box-tiny" : variant == "stable" ? "sing-box" : "sing-box-extended";
  assert(restore_sing_box_package_variant(variant));
  assert(network == 0);
  assert(installed == "1.11.9-r1");
}
rollback_package = null;
assert(!restore_sing_box_package_variant("tiny"));
assert(network == 0);
`);
const common = `
let as_string = v => v == null ? "" : "" + v;
function assert(ok) { if (!ok) { warn("Rollback preflight assertion failed\\n"); exit(1); } }
`;
fs.writeFileSync(`${dir}/metadata.uc`, common + `
let apk = false;
let present = true;
let verify = true;
let meta = { name: "sing-box-tiny", version: "1.11.9-r1", arch: "aarch64_cortex-a53", "installed-size": "4096" };
let is_apk = () => apk;
let file_nonempty = path => present;
let rollback_archive_field = (path, key) => meta[key];
let rollback_archive_digest = path => "abc";
let read_openwrt_release_value = key => "aarch64_cortex-a53";
let command_output_from_args = args => apk ? "aarch64" : "arch all 1\\narch aarch64_cortex-a53 10\\n";
let command_success_from_args = args => verify;
let command_success = command => verify;
let shell_quote = v => v;
${extract('rollback_archive_info')}
for (let use_apk in [ false, true ]) {
  apk = use_apk;
  assert(rollback_archive_info("old.pkg", "sing-box-tiny", "1.11.9-r1") != null);
  assert(rollback_archive_info("old.pkg", "sing-box", "1.11.9-r1") == null);
  assert(rollback_archive_info("old.pkg", "sing-box-tiny", "1.12.0-r1") == null);
  meta.arch = "mipsel_24kc";
  assert(rollback_archive_info("old.pkg", "sing-box-tiny", "1.11.9-r1") == null);
  meta.arch = "aarch64_cortex-a53";
  verify = false;
  assert(rollback_archive_info("old.pkg", "sing-box-tiny", "1.11.9-r1") == null);
  verify = true;
  present = false;
  assert(rollback_archive_info("old.pkg", "sing-box-tiny", "1.11.9-r1") == null);
  present = true;
}
`);
fs.writeFileSync(`${dir}/closure.uc`, common + `
let apk = false;
let is_apk = () => apk;
let database = "Package: sing-box-tiny\\nVersion: 1.11.9-r1\\nStatus: install ok installed\\nDepends: virtual-lib (>= 1), libc\\n\\nPackage: real-lib\\nVersion: 1-r1\\nStatus: install ok installed\\nProvides: virtual-lib\\nDepends: libc\\n\\nPackage: libc\\nVersion: 1-r1\\nStatus: install ok installed\\n";
let read_file = path => database;
let versions = { "sing-box-tiny": "1.11.9-r1", "real-lib": "1-r1", libc: "1-r1" };
let installed_package_version = name => versions[name];
let query = '[{"name":"sing-box-tiny","version":"1.11.9-r1"},{"name":"real-lib","version":"1-r1"},{"name":"libc","version":"1-r1"}]';
let command_output_from_args = args => query;
${extract('rollback_installed_packages')}
for (let use_apk in [ false, true ]) {
  apk = use_apk;
  let packages = rollback_installed_packages("sing-box-tiny", "1.11.9-r1");
  assert(packages != null && length(packages) == 3);
  assert(rollback_installed_packages("sing-box-tiny", "wrong") == null);
}
apk = false;
database = replace(database, "virtual-lib (>= 1)", "missing-dependency");
assert(rollback_installed_packages("sing-box-tiny", "1.11.9-r1") == null);
apk = true;
query = '[]';
assert(rollback_installed_packages("sing-box-tiny", "1.11.9-r1") == null);
query = '{bad json';
assert(rollback_installed_packages("sing-box-tiny", "1.11.9-r1") == null);
`);
fs.writeFileSync(`${dir}/stage.uc`, common + `
let rollback_package = null;
let rollback_package_files = [];
let rollback_packages = [];
let tmp_dir = "/stage";
let missing = "libc";
let checked_storage = 0;
let init_tmp_dir = () => true;
let is_apk = () => false;
let ensure_dir = path => true;
let write_file = (path, body) => true;
let command_output_from_args = args => "arch all 1\\n";
let installed_package_version = name => "old-r1";
let rollback_installed_packages = (name, version) => [ { name, version }, { name: "libc", version: "old-r2" } ];
let stage_rollback_archive = (name, version, directory) => name == missing ? null : { name, version, path: directory + "/" + name + ".ipk", size: 100 };
let ensure_install_storage = (component, action, size) => { checked_storage = size; };
let updates_log = (message, level) => null;
${extract('stage_previous_sing_box_package')}
assert(!stage_previous_sing_box_package("tiny", "install"));
assert(checked_storage == 0);
missing = "";
assert(stage_previous_sing_box_package("tiny", "install"));
assert(checked_storage == 200 && length(rollback_package_files) == 2);
assert(rollback_package.version == "old-r1");
assert(stage_previous_sing_box_package("extended-compressed", "install"));
assert(rollback_package == null && length(rollback_package_files) == 0);
`);
fs.writeFileSync(`${dir}/offline-command.uc`, common + `
let apk = false;
let tmp_dir = "/stage";
let digest = "original";
let command = "";
let rollback_packages = [ { name: "sing-box-tiny", version: "old-r1", path: "/stage/old.ipk", digest: "original" } ];
let is_apk = () => apk;
let rollback_archive_digest = path => digest;
let shell_quote = v => "'" + v + "'";
let command_from_args = args => join(" ", args);
let run_logged_install = (message, value) => { command = value; return true; };
let installed_package_version = name => "old-r1";
${extract('pkg_install_rollback_files')}
assert(pkg_install_rollback_files([ "/stage/old.ipk" ]));
assert(index(command, "OPKG_CONF_DIR='/stage/rollback/empty'") >= 0);
assert(index(command, "-f /stage/rollback/offline.conf") >= 0);
apk = true;
assert(pkg_install_rollback_files([ "/stage/old.apk" ]));
assert(index(command, "--no-network") >= 0);
command = "";
digest = "corrupt";
assert(!pkg_install_rollback_files([ "/stage/old.apk" ]));
assert(command == "");
`);
// Guard every switching entry point: preflight failure must occur before stop.
for (const name of ['install_sing_box_extended_package', 'install_sing_box_extended', 'install_package_sing_box']) {
  const body = extract(name);
  const stage = body.indexOf('if (!stage_previous_sing_box_package(');
  const stop = body.indexOf('stop_trafira_before_sing_box_change();');
  if (stage < 0 || stop < stage || !body.slice(stage, stop).includes('action_fail('))
    throw Error(`${name}: rollback preflight must abort before stopping service`);
}
const extended = extract('install_sing_box_extended_package');
if (extended.indexOf('move_file_to_backup("/usr/bin/sing-box"') > extended.indexOf('run_logged_pkg_remove_sing_box_conflict('))
  throw Error('Tiny/stable binary backup must precede removal');
NODE
for fixture in "$WORK_DIR/"*.uc; do
  ucode "$fixture"
done
printf 'offline sing-box package rollback passed\n'
