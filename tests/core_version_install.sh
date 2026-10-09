#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" "$WORK_DIR/test.uc" <<'NODE'
const fs = require('fs');
const [path, output] = process.argv.slice(2);
const source = fs.readFileSync(path, 'utf8');
function extract(name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw Error(`Missing integration function ${name}`);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
fs.writeFileSync(output, `
let selected_core={expected_digest:"before",original_version:"1.14.2",candidate:{version:"1.14.1-r1",repository_package:"sing-box"}};
let selected_error="",current="1.14.2",digest="before",finished=0,healthy=true;
let selected_hooks={current:()=>current,digest:()=>digest};
let core_selection={finish:()=>{finished++;return {success:false,error:"pin_write_failed"};}};
${extract('selected_core_unchanged')}
${extract('finish_selected_core')}
assert(selected_core_unchanged(),"unchanged candidate may stop service");
digest="edited";
assert(!selected_core_unchanged() && selected_error=="conflict","late configuration edit blocks stop");
digest="before";current="1.14.3";
assert(!selected_core_unchanged(),"late binary change blocks stop");
assert(!finish_selected_core() && finished==1 && selected_error=="pin_write_failed","pin failure enters existing rollback branch");
selected_core=null;
assert(finish_selected_core() && selected_core_unchanged(),"legacy operations unchanged");
`);
// Verify each existing installer retains rollback data until the selected
// transaction has confirmed the running version and committed the pin.
for (const name of ['install_sing_box_extended_package', 'install_sing_box_extended', 'install_package_sing_box']) {
  const body=extract(name);
  if (!body.includes('!wait_trafira_running_after_sing_box_change() || !finish_selected_core()'))
    throw Error(`${name}: selected finalization is not inside rollback boundary`);
}
NODE
ucode "$WORK_DIR/test.uc"
