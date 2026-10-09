#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.keep=original\n' >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let p=require("components.core_pin"),uci=require("core.uci");
assert(p.read()==null,"no implicit pin");
assert(!p.write({version:"https://attacker.invalid",variant:"stable"}).success,"invalid version rejected");
assert(p.write({version:"1.14.1-r1",variant:"stable"}).success,"pin saved");
assert(p.read().version=="1.14.1-r1" && uci.get("trafira.settings.keep")=="original","pin scoped to two fields");
let commit=uci.commit,attempts=0;
uci.commit=function(name){attempts++;return attempts==1?false:commit(name);};
let failed=p.write({version:"1.14.2-r1",variant:"stable"});
uci.commit=commit;
assert(!failed.success && failed.restored && p.read().version=="1.14.1-r1","failed commit restores previous pin");
assert(p.write(null).success && p.read()==null,"unpin");
assert(p.request_valid({action:"install",candidate_id:"stable~aarch64~apk~1.14.1-r1",pin:true,expected_current_version:"1.14.2"}),"bounded version request");
assert(!p.request_valid({action:"install",candidate_id:"https://attacker.invalid",pin:true,expected_current_version:"1.14.2"}),"caller URL rejected");
assert(!p.request_valid({action:"install",candidate_id:"valid",pin:true,expected_current_version:"1.14.2",asset_url:"https://attacker.invalid"}),"unknown request field rejected");
assert(!p.request_valid({action:"install",candidate_id:"valid",pin:"yes",expected_current_version:"1.14.2"}),"pin boolean required");
print("core pin persistence checks passed\n");
'
