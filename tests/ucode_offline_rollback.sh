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
NODE
ucode "$WORK_DIR/restore.uc"
printf 'offline sing-box package rollback passed\n'
