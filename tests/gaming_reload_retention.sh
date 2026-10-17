#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
python3 - "$ROOT_DIR" "$WORK_DIR/test.uc" <<'PY'
from pathlib import Path
import sys
source=(Path(sys.argv[1])/'trafira/files/usr/lib/service/lifecycle.uc').read_text()
fn=source[source.index('function rebuild_nft_for_reload('):source.index('\nfunction singbox_init_config()')]
Path(sys.argv[2]).write_text('''
let calls=[],reply=0;
function nft_rebuild_runtime(retain){push(calls,!!retain);return retain?reply:0;}
function log_message(){}
''' + fn + '''
for(let scenario in [
 {changed:0,remote:1,reply:0,want_update:0,want_calls:[true],want:0},
 {changed:0,remote:1,reply:2,want_update:1,want_calls:[true,false],want:0},
 {changed:0,remote:1,reply:1,want_update:1,want_calls:[true],want:1},
 {changed:1,remote:1,reply:0,want_update:1,want_calls:[false],want:0},
 {changed:0,remote:0,reply:0,want_update:1,want_calls:[false],want:0}
]) {
 calls=[];reply=scenario.reply;
 let plan={changed_list:scenario.changed,needs_list_update:1};
 assert(rebuild_nft_for_reload(plan,scenario.remote)==scenario.want,"transaction failure must propagate");
 assert(plan.needs_list_update==scenario.want_update,"only complete reuse skips downloading");
 assert(sprintf("%J",calls)==sprintf("%J",scenario.want_calls),"fallback only follows a preflight miss");
}
print("Reload retains unchanged sets, falls back before writes, and never conceals transaction failure\\n");
''')
PY
ucode "$WORK_DIR/test.uc"
