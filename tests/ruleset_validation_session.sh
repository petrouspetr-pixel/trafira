#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib" TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache" VALIDATION_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RULESET_CACHE_DIR"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
[ "$1" = rule-set ] || exit 1
printf 'codec\n' >>"$VALIDATION_TEST/calls"
grep -q valid-rules "$3" || exit 1
cp "$3" "$5"
SH
chmod +x "$WORK_DIR/bin/sing-box"
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$TRAFIRA_LIB" -e '
let fs=require("fs"),cache=require("singbox.ruleset_cache"),bootstrap=require("singbox.ruleset_bootstrap"),root=getenv("VALIDATION_TEST");
let rule={type:"remote",tag:"one",format:"binary",url:"https://lists.example/test",http_client:{}},config={route:{rule_set:[rule,{...rule,tag:"same-bytes"}]}};
fs.writefile(cache.path(rule),"valid-rules");
let path=root+"/config.json";
fs.writefile(path,sprintf("%J",config));
assert(require("singbox.failure_store").save_base(path,config,[]),"baseline fixture");
assert(bootstrap.prepare_file(path,"1.14.1"),"cached bootstrap and baseline succeed");
let count=length(filter(split(trim(fs.readfile(root+"/calls")),"\n"),(s)=>length(s)>0));
assert(count==1,"identical snapshot validated once across bootstrap, protection and baseline; got "+count);
let session={};
assert(cache.validate(rule,cache.path(rule),session),"fresh operation validates bytes");
fs.writefile(cache.path(rule),"bad-rules!!");
assert(!cache.validate(rule,cache.path(rule),session),"same-size mutation never reuses a validation");
fs.writefile(cache.path(rule),"valid-rules");
assert(cache.validate({...rule,format:"source"},cache.path(rule),session),"format has an independent validation");
assert(length(filter(split(trim(fs.readfile(root+"/calls")),"\n"),(s)=>length(s)>0))==4,"one validation per content and format, never per alias");
print("operation-scoped snapshot validation checks passed\n");
'
