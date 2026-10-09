#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR" "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"
python3 - "$ROOT_DIR" "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root/'trafira/files/usr/lib/service/lifecycle.uc').read_text()
fn = source[source.index('function reload_guarded(reason) {'):source.index('\nfunction reload_tracked(reason) {')]
(work/'adapter.uc').write_text('''
let fs=require("fs"),applied=require("service.applied_config");
const CONFIG_NAME="trafira",LIB_DIR="/fixture",SERVICE_INIT="/fixture/init",RUNTIME_STATE_DIR=getenv("TRAFIRA_RUNTIME_STATE_DIR");
let path=getenv("TRAFIRA_CONFIG_FILE"),core=path+".json",released=false,restarted=false,failed=false;
fs.writefile(core,"{}");fs.writefile(path,"old settings");
assert(applied.save(applied.capture({config_path:core,router_origin_enabled:"1"},[])),"previous applied checkpoint");
fs.writefile(path,"new settings");
let uci_core={get_all:()=>({config_path:core,router_origin_enabled:"0"}),section_objects:()=>[{enabled:"1",failure_policy:"block"}]};
function setting_bool(){return false;}
function log_message(){}
function command_success_from_args(){return true;}
function release_start_subscription_update_lock(){released=true;}
function reload(){assert(fs.readfile(path)=="new settings","activation uses candidate");failed=true;return 1;}
function module_status(module,args){
 assert(failed && released,"failed reload releases subscription lock before restart");
 assert(module==LIB_DIR+"/service/lifecycle.uc" && args[0]=="restart","fresh lifecycle process requested");
 assert(fs.readfile(path)=="old settings","fresh process sees restored UCI, not cached candidate");
 restarted=true;return 0;
}
''' + fn + '''
assert(reload_guarded("on_config_change")==1,"failed apply remains reported as failure");
assert(restarted && fs.readfile(path)=="old settings","ordinary reload adapter restores checkpoint");
assert(!require("service.config_transaction").status().recovery_pending,"successful restore clears recovery journal");
print("ordinary reload adapter recovery checks passed\\n");
''')
PY
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/adapter.uc"
