#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CORE_CATALOG_DIR="$WORK_DIR/catalog"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),c=require("components.core_catalog");
let env={variant:"stable",architecture:"aarch64",package_type:"apk"},calls=0;
let fetch=()=>{calls++;return [{version:"1.14.1-r1",variant:"stable",architecture:"aarch64",package_type:"apk",stable:true,repository_package:"sing-box"}];};
assert(c.load(env,false,fetch,1000).entries[0].available && calls==1,"initial fetch");
assert(c.load(env,false,fetch,1500).cached_at==1000 && calls==1,"15 minute cache");
assert(c.load(env,false,fetch,1901).cached_at==1901 && calls==2,"expired refresh");
assert(c.load(env,true,fetch,1902).cached_at==1902 && calls==3,"explicit refresh");
let fail=()=>null;
let result=c.load(env,true,fail,1903);
assert(!result.success && result.error=="catalog_fetch_failed" && result.cached_at==1902,"network failure explicit, stale data labeled");
assert(c.resolve("stable~aarch64~apk~1.14.1-r1",env,fail)==null,"install resolution cannot use stale cache after failed refresh");
let file=c.path(env);
assert(fs.stat(file).mode%512==384,"catalog private");
fs.writefile(file,sprintf("%02100000d",1));
assert(!c.load(env,false,fail,1904).success,"oversized cached response rejected");
print("core catalog cache checks passed\n");
'
