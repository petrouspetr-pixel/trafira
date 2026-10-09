#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TRAFIRA_LIB="$WORK/lib" TRAFIRA_WARP_PACKAGE_CACHE="$WORK/cache"
mkdir -p "$TRAFIRA_LIB/components" "$TRAFIRA_WARP_PACKAGE_CACHE"
cat >"$TRAFIRA_LIB/components/action.uc" <<'UCODE'
let fs=require("fs"),cache=getenv("TRAFIRA_WARP_PACKAGE_CACHE");
assert(ARGV[0]=="component-action" && ARGV[1]=="warp" && ARGV[2]=="recover","recovery command");
fs.writefile(cache+"/called","yes");exit(fs.stat(cache+"/fail")?1:0);
UCODE
ucode -L "$ROOT/trafira/files/usr/lib" -e '
let fs=require("fs"),r=require("integrations.warp_package_recovery"),path=getenv("TRAFIRA_WARP_PACKAGE_CACHE");
assert(r.before_start(),"absent component does not run commands");
assert(!fs.stat(path+"/called"),"no command when no journal");
fs.writefile(path+"/journal.json","{}");
assert(r.before_start() && fs.stat(path+"/called"),"durable journal recovers before main starts");
fs.writefile(path+"/fail","");assert(!r.before_start(),"failed recovery prevents unsafe startup");
print("WARP boot package recovery passed\n");
'
