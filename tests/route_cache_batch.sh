#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),codec=require("diagnostics.route_decode_cache"),root=getenv("TRAFIRA_RUNTIME_STATE_DIR"),ls=fs.lsdir,scans=0;
fs.lsdir=function(path){if(path==root+"/route-decode-cache")scans++;return ls(path);};
let pending={};for(let n=0;n<55;n++)pending[sprintf("%064x",n)]={rules:[],match:{value:"no",missing:[]}};
if(codec.put_many)assert(codec.put_many(pending,root),"publish batch");
else for(let key,value in pending)assert(codec.put(key,value,root),"publish legacy entry");
assert(scans==1,"one cache publication batch must inventory the directory once, not once per entry");
for(let key,value in pending)assert(codec.get(key,4096).data.match.value=="no","every batch entry is digest verified");
let key=sprintf("%064x",1);
fs.writefile(root+"/route-decode-cache/"+key+".json","{}");
assert(codec.get(key,4096)==null,"corrupt batch entry remains unusable");
print("batch cache inventory and integrity checks passed\n");
'
