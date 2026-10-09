#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CONFIG_FILE="$WORK_DIR/uci" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" FIXTURE_CORE="$WORK_DIR/core.json"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e 'let fs=require("fs"),a=require("service.applied_config");
let path=getenv("TRAFIRA_CONFIG_FILE"),core=getenv("FIXTURE_CORE");
fs.writefile(path,"config settings settings\n option shutdown_correctly 1\n");fs.writefile(core,"{}");
let old=a.capture({config_path:core,alice_mode_enabled:"0"},[]);
fs.writefile(path,"config settings settings\n option shutdown_correctly 0\n");
assert(a.save(old) && a.active(),"internal lifecycle flag does not invalidate checkpoint capture");
let candidate=a.capture({config_path:core,alice_mode_enabled:"1"},[]);
fs.writefile(path,"config settings settings\n option alice_mode_enabled 1\n");
assert(!a.save(candidate),"concurrent user change refuses checkpoint");
assert(!a.active(),"failed checkpoint cannot keep falsely verified previous capture settings");
assert(a.save(a.capture({config_path:core},[])),"new verified checkpoint saved");
assert(!a.save(a.capture({config_path:core+".missing"},[])),"missing generated config rejected");
assert(!a.active(),"failed core digest cannot keep obsolete checkpoint");
assert(a.save(a.capture({config_path:core},[])),"checkpoint restored");
fs.unlink(core);
assert(!a.refresh(core) && !a.active(),"refresh requires real generated config digest");
print("applied configuration checkpoint checks passed\n");
'
