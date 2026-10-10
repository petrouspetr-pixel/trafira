#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),r=require("service.runtime_apply"),t=require("service.config_transaction"),hash=require("singbox.provenance").hash_file;
let path=getenv("TRAFIRA_CONFIG_FILE"),candidate=path+".candidate",guarded=false;
let a="config settings settings\n\toption label A\n",b="config settings settings\n\toption label B\n",c="config settings settings\n\toption label C\n";
let hooks={validate:()=>true,capture:()=>({running:true,enabled:true}),guard:()=>{guarded=true;return true;},clear:()=>{guarded=false;return true;},activate:()=>true,restore:()=>true};
function applied(text){return {schema:1,config_text:text,settings:{router_origin_enabled:"1"},protected:true};}
fs.writefile(path,a);fs.writefile(candidate,b);
assert(t.apply(candidate,hash(path),"profile",hooks).success,"user applies profile B");
assert(fs.readfile(t.previous_path())==a,"profile A is available for user restoration");
assert(r.apply(applied(b),{},hooks).success && !guarded,"unchanged automatic network reload succeeds");
assert(fs.readfile(t.previous_path())==a,"unchanged network reload must preserve the previous user profile A");
let b_hint=b+"\toption shutdown_correctly 1\n";
fs.writefile(path,b_hint);
assert(r.apply(applied(b),{},hooks).success,"internal shutdown hint may change during reload");
assert(fs.readfile(t.previous_path())==a,"internal shutdown hint must not evict profile A");
fs.writefile(path,c);
assert(r.apply(applied(b_hint),{},hooks).success,"real settings change applies through runtime reload");
assert(fs.readfile(t.previous_path())==b_hint,"real settings change retains the exact prior settings");
fs.writefile(path,"broken candidate");hooks.activate=()=>false;
let failed=r.apply(applied(c),{},hooks);
assert(!failed.success && failed.restored && fs.readfile(path)==c && !guarded,"failed changed reload restores active config C");
assert(fs.readfile(t.previous_path())==b_hint,"failed reload does not overwrite the user restoration point");
hooks.activate=()=>true;fs.writefile(candidate,c);
assert(t.apply(candidate,hash(path),"profile",hooks).success,"explicit profile operation remains a new user transaction");
assert(fs.readfile(t.previous_path())==c,"explicit user operation records its own predecessor");
fs.writefile(path,a);fs.writefile(candidate,b);
assert(t.apply(candidate,hash(path),"profile",hooks).success,"prepare crash scenario with A saved and B active");
'
# Real process death proves that preserving previous.uci does not bypass the
# separate emergency BACKUP/JOURNAL, even when the candidate is unchanged.
set +e
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),r=require("service.runtime_apply"),path=getenv("TRAFIRA_CONFIG_FILE");
let previous={schema:1,config_text:fs.readfile(path),settings:{router_origin_enabled:"1"},protected:true};
r.apply(previous,{}, {validate:()=>true,capture:()=>({running:true,enabled:true}),guard:()=>true,clear:()=>true,activate:()=>{exit(79);},restore:()=>true});
'
status=$?
set -e
test "$status" = 79
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),t=require("service.config_transaction"),path=getenv("TRAFIRA_CONFIG_FILE");
assert(t.status().recovery_pending,"interrupted unchanged reload retains its emergency journal");
fs.writefile(path,"interrupted runtime state");
assert(t.before_start().success,"startup recovers the interrupted reload");
assert(fs.readfile(path)=="config settings settings\n\toption label B\n","emergency recovery restores active B, not previous profile A");
assert(fs.readfile(t.previous_path())=="config settings settings\n\toption label A\n","user profile A survives crash recovery");
assert(!t.status().recovery_pending,"recovery consumes only the emergency journal");
'
printf 'Runtime reload preserves user restoration point and emergency recovery passed\n'
