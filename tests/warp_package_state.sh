#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/trafira-warp-state.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export FIXTURE="$WORK" TRAFIRA_RUNTIME_STATE_DIR="$WORK/runtime" TRAFIRA_WARP_STATE="$WORK/private" TRAFIRA_WARP_RUNTIME="$WORK/run"
mkdir -p "$WORK/lib/warp" "$WORK/runtime" "$WORK/private"
cat >"$WORK/lib/warp/transport.uc" <<'UC'
return {restore:()=>true};
UC
cat >"$WORK/lib/warp/runtime.uc" <<'UC'
let fs=require("fs"),s=require("warp.state");
return {activate:(config)=>({success:s.save(s.DIRECTORY+"/transport.json",{...config,generation:2})}),refresh_health:()=>({running:true,https_ok:!!fs.stat(getenv("FIXTURE")+"/healthy"),warp:true})};
UC
ucode -L "$WORK/lib" -L "$ROOT/trafira/files/usr/lib" -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let fs=require("fs"),p=require("integrations.warp_package_state"),s=require("warp.state"),l=require("service.operation_lock"),root=getenv("FIXTURE"),path=root+"/state.json";
let file=fs.open(path,"we",384);file.write(sprintf("%J",{transport:{running:true,config:{enabled:false}},files:{}}));file.close();
assert(!p.execute("resume",path).success,"unrelated process cannot resume service");
let lock=l.acquire("package-test");assert(lock,"package coordinator");
assert(p.execute("resume",path).success && s.load(s.DIRECTORY+"/transport.json").enabled===false,"running service keeps independently disabled boot state");
assert(!p.execute("restore",path).success,"unhealthy rollback remains pending");
fs.writefile(root+"/healthy","");assert(p.execute("restore",path).success,"restored running tunnel must pass HTTPS");
l.release(lock);print("WARP package state authority, boot flag and recovery health passed\n");
'
