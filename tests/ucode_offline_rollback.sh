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
let rollback_files_valid = () => true;
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
// Real gzip/tar package and SHA256 parsing, with only the router's architecture
// list substituted. All archive bytes are generated locally; no router/network.
const cp = require('child_process');
const archiveDir = `${dir}/ipk`;
fs.mkdirSync(`${archiveDir}/control`, {recursive: true});
fs.mkdirSync(`${archiveDir}/data`, {recursive: true});
fs.writeFileSync(`${archiveDir}/control/control`, 'Package: sing-box-tiny\nVersion: 1.11.9-r1\nArchitecture: aarch64_cortex-a53\nInstalled-Size: 1\n');
fs.writeFileSync(`${archiveDir}/data/binary`, Buffer.alloc(8192, 97));
cp.execFileSync('tar', ['-czf', `${archiveDir}/control.tar.gz`, '-C', `${archiveDir}/control`, './control']);
cp.execFileSync('tar', ['-czf', `${archiveDir}/data.tar.gz`, '-C', `${archiveDir}/data`, './binary']);
cp.execFileSync('tar', ['-czf', `${archiveDir}/old.ipk`, '-C', archiveDir, 'control.tar.gz', 'data.tar.gz']);
fs.writeFileSync(`${archiveDir}/broken.ipk`, 'not an archive');
fs.mkdirSync(`${archiveDir}/empty-control`);
fs.mkdirSync(`${archiveDir}/empty-data`);
fs.mkdirSync(`${archiveDir}/empty-package`);
fs.writeFileSync(`${archiveDir}/empty-control/control`, 'Package: libpthread\nVersion: 1-r1\nArchitecture: aarch64_cortex-a53\nInstalled-Size: 0\n');
cp.execFileSync('tar', ['-czf', `${archiveDir}/empty-package/control.tar.gz`, '-C', `${archiveDir}/empty-control`, './control']);
cp.execFileSync('tar', ['-czf', `${archiveDir}/empty-package/data.tar.gz`, '-C', `${archiveDir}/empty-data`, '.']);
cp.execFileSync('tar', ['-czf', `${archiveDir}/empty.ipk`, '-C', `${archiveDir}/empty-package`, 'control.tar.gz', 'data.tar.gz']);
fs.writeFileSync(`${dir}/real-archive.uc`, common + `
let fs = require("fs");
let is_apk = () => false;
let read_openwrt_release_value = key => "aarch64_cortex-a53";
${['shell_quote','command_from_args','command_status','command_success','command_success_from_args','command_output','file_nonempty'].map(extract).join('\n')}
function command_output_from_args(args) {
  if (args[0] == "opkg") return "arch all 1\\narch aarch64_cortex-a53 10\\n";
  return command_output(command_from_args(args));
}
${['rollback_archive_field','rollback_archive_digest','rollback_ipk_unpacked_bytes','rollback_archive_info'].map(extract).join('\n')}
let path = ${JSON.stringify(`${archiveDir}/old.ipk`)};
let info = rollback_archive_info(path, "sing-box-tiny", "1.11.9-r1");
assert(info != null && info.size >= 8192 && length(info.digest) == 64);
assert(rollback_archive_info(path, "sing-box-tiny", "1.12.0-r1") == null);
assert(rollback_archive_info(${JSON.stringify(`${archiveDir}/broken.ipk`)}, "sing-box-tiny", "1.11.9-r1") == null);
let empty_info = rollback_archive_info(${JSON.stringify(`${archiveDir}/empty.ipk`)}, "libpthread", "1-r1");
assert(empty_info != null && empty_info.size == 0);
let old_digest = info.digest;
fs.writefile(path, "damaged after staging");
assert(rollback_archive_digest(path) != old_digest);
`);
fs.writeFileSync(`${dir}/metadata.uc`, common + `
let apk = false;
let present = true;
let verify = true;
let meta = { name: "sing-box-tiny", version: "1.11.9-r1", arch: "aarch64_cortex-a53", "installed-size": "4096" };
let is_apk = () => apk;
let file_nonempty = path => present;
let rollback_archive_field = (path, key) => meta[key];
let rollback_archive_digest = path => "abc";
let unpacked = 4096;
let rollback_ipk_unpacked_bytes = path => unpacked;
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
meta.name = "libpthread";
unpacked = 0;
for (let use_apk in [ false, true ]) {
  apk = use_apk;
  meta["installed-size"] = "0";
  let empty = rollback_archive_info("empty.pkg", "libpthread", "1.11.9-r1");
  assert(empty != null && empty.size == 0);
  for (let invalid in [ "", "garbage", "-1", "10bytes", null ]) {
    meta["installed-size"] = invalid;
    assert(rollback_archive_info("empty.pkg", "libpthread", "1.11.9-r1") == null);
  }
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
let rollback_apk_world = null;
let tmp_dir = "/stage";
let apk = false;
let world = "base-files\\nsing-box-tiny~1.11\\n";
let fs = { readfile: path => world };
let missing = "libc";
let checked_storage = 0;
let init_tmp_dir = () => true;
let is_apk = () => apk;
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
apk = true;
assert(stage_previous_sing_box_package("tiny", "install"));
assert(rollback_apk_world == world);
world = null;
assert(!stage_previous_sing_box_package("tiny", "install"));
`);
fs.writeFileSync(`${dir}/download-capacity.uc`, common + `
let apk = false;
let is_apk = () => apk;
let metadata = "Package: sing-box-tiny\\nVersion: old-r1\\nSize: 4096\\n\\nPackage: sing-box-tiny\\nVersion: new-r1\\nSize: 9999\\n";
let command_output_from_args = args => metadata;
${extract('rollback_repository_size')}
assert(rollback_repository_size("sing-box-tiny", "old-r1") == 4096);
assert(rollback_repository_size("sing-box-tiny", "unavailable-r1") == 0);
apk = true;
metadata = '[{"name":"sing-box-tiny","version":"old-r1","file-size":4096}]';
assert(rollback_repository_size("sing-box-tiny", "old-r1") == 4096);
assert(rollback_repository_size("sing-box-tiny", "new-r1") == 0);
metadata = '{}';
assert(rollback_repository_size("sing-box-tiny", "old-r1") == 0);
`);
fs.writeFileSync(`${dir}/offline-command.uc`, common + `
let apk = false;
let tmp_dir = "/stage";
let digest = "original";
let command = "";
let rollback_packages = [ { name: "sing-box-tiny", version: "old-r1", path: "/stage/old.ipk", digest: "original" } ];
let rollback_apk_world = "base-files\\nsing-box-tiny~1.11\\n";
let world = rollback_apk_world;
let pending = "";
let fs = { rename: (source, target) => { world = pending; return true; } };
let write_file = (path, data) => { pending = data; return true; };
let remove_file = path => true;
let owner_pid = () => "123";
let is_apk = () => apk;
let rollback_archive_digest = path => digest;
let file_nonempty = path => true;
let shell_quote = v => "'" + v + "'";
let command_from_args = args => join(" ", args);
let run_logged_install = (message, value) => { command = value; if (apk) world = "base-files\\nlibc=hash-pinned\\nsing-box-tiny=hash-pinned\\n"; return true; };
let installed_package_version = name => "old-r1";
${extract('rollback_files_valid')}
${source.includes('function restore_rollback_apk_world(') ? extract('restore_rollback_apk_world') : ''}
${extract('pkg_install_rollback_files')}
assert(pkg_install_rollback_files([ "/stage/old.ipk" ]));
assert(index(command, "OPKG_CONF_DIR='/stage/rollback/empty'") >= 0);
assert(index(command, "-f /stage/rollback/offline.conf") >= 0);
apk = true;
assert(pkg_install_rollback_files([ "/stage/old.apk" ]));
assert(index(command, "--no-network") >= 0);
assert(world == rollback_apk_world);
command = "";
digest = "corrupt";
assert(!pkg_install_rollback_files([ "/stage/old.apk" ]));
assert(command == "");
`);
fs.writeFileSync(`${dir}/recovery-retention.uc`, common + `
let tmp_dir = "/tmp/trafira-updates.fixture";
let retain_rollback_files = true;
let removed = [];
let moved = "";
let logged = "";
let fs = { rename: (source, target) => { moved = target; return true; } };
let command_success_from_args = args => { if (args[0] == "rm") push(removed, args[2]); return true; };
let cleanup_stale_tmp_files = () => null;
let updates_log = (message, level) => { logged = message; };
${extract('cleanup_tmp_dir')}
cleanup_tmp_dir();
assert(length(removed) == 0);
assert(index(moved, "/tmp/trafira-recovery.") == 0);
assert(index(logged, moved) >= 0);
tmp_dir = "/tmp/trafira-updates.success";
retain_rollback_files = false;
cleanup_tmp_dir();
assert(length(removed) == 1 && removed[0] == "/tmp/trafira-updates.success");
`);
fs.writeFileSync(`${dir}/recovery-failure.uc`, common + `
let retain_rollback_files = false;
let package_ok = false;
let binary_ok = true;
let sing_box_variant_is_package_managed = variant => true;
let restore_sing_box_package_variant = variant => package_ok;
let restore_sing_box_backup = path => binary_ok;
let restore_rollback_apk_world = () => true;
let updates_log = (message, level) => null;
${extract('restore_sing_box_install_backup')}
assert(restore_sing_box_install_backup("tiny", "/backup/binary"));
assert(retain_rollback_files);
retain_rollback_files = false;
binary_ok = false;
assert(!restore_sing_box_install_backup("tiny", "/backup/binary"));
assert(retain_rollback_files);
retain_rollback_files = false;
package_ok = true;
assert(restore_sing_box_install_backup("tiny", "/backup/binary"));
assert(!retain_rollback_files);
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
failed=0
for fixture in "$WORK_DIR/"*.uc; do
  if ! ucode "$fixture"; then
    printf 'FAILED rollback fixture: %s\n' "$(basename "$fixture")" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ]
printf 'offline sing-box package rollback passed\n'
