#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e 'let fs=require("fs"),r=require("service.runtime_apply"),t=require("service.config_transaction");
let path=getenv("TRAFIRA_CONFIG_FILE"),guarded=false,restored=false;
fs.writefile(path,"new settings");
let previous={schema:1,config_text:"old settings",settings:{router_origin_enabled:"0"},protected:false};
let hooks={validate:()=>true,capture:()=>({running:true,enabled:true}),guard:()=>{guarded=true;return true;},clear:()=>{guarded=false;return true;},activate:()=>false,restore:()=>{restored=true;return true;}};
let result=r.apply(previous,{router_origin_enabled:"1"},hooks);
assert(!result.success && result.restored && restored,"late reload failure restores runtime");
assert(fs.readfile(path)=="old settings" && !guarded,"old UCI restored before guard removed");
fs.writefile(path,"new settings");hooks.restore=()=>false;
result=r.apply(previous,{router_origin_enabled:"1"},hooks);
assert(!result.success && result.rollback_error && guarded,"failed restoration keeps transition guard");
assert(t.status().recovery_pending,"crash recovery journal retained");
let script=r.guard_script({source_network_interfaces:["br-lan"],router_origin_enabled:"1"},{});
assert(index(script,"hook forward")>=0 && index(script,"iifname")>=0,"unmarked forwarded packets protected during nft table gap");
assert(index(script,"hook output")>=0 && index(script,"ct direction reply")>=0,"router output protected without blocking management replies");
print("runtime apply recovery checks passed\n");
'
