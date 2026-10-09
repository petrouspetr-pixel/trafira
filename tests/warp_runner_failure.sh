#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib/warp"
cat >"$WORK/lib/fake_fs.uc" <<'UC'
let checked=false;
return {stat:()=>{if(!checked){checked=true;return null;}return {};},popen:()=>({close:()=>0}),lstat:()=>({}),readfile:()=>"0"};
UC
cat >"$WORK/lib/uci.uc" <<'UC'
return {cursor:()=>({get_all:()=>({})})};
UC
cat >"$WORK/lib/warp/state.uc" <<'UC'
return {DIRECTORY:"/private",RUNTIME:"/run",load:(path)=>index(path,"daemon")>=0?{pid:"1234",ticks:"7"}:{enabled:true,interface:"tfwarp0",generation:1},ensure:()=>true,remove:()=>true,save:()=>true};
UC
cat >"$WORK/lib/warp/transport.uc" <<'UC'
return {valid_config:()=>true,owned:()=>true,quote:(v)=>v,output:()=>null};
UC
cat >"$WORK/lib/warp/job.uc" <<'UC'
return {live:()=>true};
UC
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
s=(root/'components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp/warp/runner.uc').read_text().replace('require("fs")','require("fake_fs")').replace('system(', 'test_system(')
s='function test_system(command){if(index(command,"kill")>=0)print("UNSAFE PID SIGNAL\\n");return 0;}\n'+s
(work/'runner.uc').write_text(s)
PY
rc=0
ucode -L "$WORK/lib" "$WORK/runner.uc" >"$WORK/result" 2>&1 || rc=$?
[ "$rc" = 1 ]
cat "$WORK/result"
if grep -q 'UNSAFE PID SIGNAL' "$WORK/result"; then exit 1; fi
echo 'WARP runner failure delegates cleanup without PID-based signal'
