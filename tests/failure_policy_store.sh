#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export FAILURE_STORE_TEST="$WORK_DIR" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),s=require("singbox.failure_store"),root=getenv("FAILURE_STORE_TEST"),path=root+"/config.json";
fs.writefile(path,"{\"route\":{\"rules\":[]}}\n");
let base={route:{rules:[]},dns:{servers:[],rules:[]},outbounds:[]};
let sections=[{".name":"vpn",action:"connection",failure_policy:"block",password:"private"}];
assert(s.save_base(path,base,sections),"private baseline saved");
let loaded=s.load(path);
assert(loaded && loaded.generation && loaded.sections[0].password==null,"baseline descriptor whitelists section metadata");
assert((fs.stat(path+".failure-policy.json").mode & 63)==0,"sidecar private");
assert(s.publish(loaded.generation,path,{vpn:{mode:"primary",observed_at:10}}),"runtime state published");
assert(s.load(path).states.vpn.mode=="primary","current runtime recognized");
fs.writefile(path,"{\"changed\":true}");
assert(s.load(path)==null,"modified applied config invalidates policy state");
print("failure policy snapshot checks passed\n");
'
