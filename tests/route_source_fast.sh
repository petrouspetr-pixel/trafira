#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export ROUTE_SOURCE_TEST="$WORK_DIR" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
printf 'compile\n' >>"$ROUTE_SOURCE_TEST/calls"
[ ! -f "$ROUTE_SOURCE_TEST/reject" ] || exit 1
cp "$3" "$5"
SH
chmod +x "$WORK_DIR/bin/sing-box"
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),codec=require("diagnostics.route_decode_cache"),root=getenv("ROUTE_SOURCE_TEST"),proof={};
let source={version:3,rules:[{ip_cidr:["192.0.2.0/24","2001:db8::/32"]}]};
for(let n=0;n<10;n++){
 let path=root+"/source-"+n;fs.writefile(path,sprintf("%J",source));
 let result=codec.decode(path,"source",3000,codec.MAX_FILE,root,proof);
 assert(result.data && result.data.rules[0].ip_cidr[1]=="2001:db8::/32","source subset retains both address families");
}
assert(length(split(trim(fs.readfile(root+"/calls")),"\n"))==1,"ten simple source files require one core compatibility probe, not ten compilations");
// A new analysis must probe its current executable rather than trust old metadata.
fs.unlink(root+"/calls");
let result=codec.decode(root+"/source-0","source",3000,codec.MAX_FILE,root,{});
assert(result.data && length(split(trim(fs.readfile(root+"/calls")),"\n"))==1,"fresh analysis has fresh capability proof");
// Invalid and unknown fields retain the actual core compiler failure path.
fs.writefile(root+"/reject","");
for(let item in [
 {version:3,rules:[{ip_cidr:["192.0.2.0/24"],unknown_flag:true}]},
 {version:3,rules:[{ip_cidr:["192.168.001.0/24"]}]},
 {version:3,rules:[{ip_cidr:["::ffff:192.168.001.1/128"]}]},
 {version:3,rules:[{ip_cidr:["2001:db8::/0128"]}]},
 {version:3,rules:[{ip_cidr:["192.0.2.0/24"]}],unexpected:true},
 {version:999,rules:[{ip_cidr:["192.0.2.0/24"]}]},
 {version:3,rules:[{}]}
]){
 fs.writefile(root+"/invalid",sprintf("%J",item));
 assert(!codec.decode(root+"/invalid","source",3000,codec.MAX_FILE,root,proof).data,"unsupported source cannot use successful subset proof");
}
assert(!codec.decode(root+"/source-0","source",3000,codec.MAX_FILE,root,{}).data,"a core rejecting version 3 cannot use the fast path");
codec.cleanup(root);
assert(!fs.stat(root+"/source-probe") && !fs.stat(root+"/codec.pid"),"probe and child marker are cleaned");
print("source compatibility proof and strict subset checks passed\n");
'
