#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TRAFIRA_WARP_STATE="$WORK/state" TRAFIRA_WARP_RUNTIME="$WORK/run"
mkdir -p "$TRAFIRA_WARP_STATE" "$TRAFIRA_WARP_RUNTIME"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let fs=require("fs"),s=require("warp.state"),j=require("warp.job");
let path=getenv("TRAFIRA_WARP_STATE")+"/test.json";
assert(s.save(path,{private_key:"private",token:"secret",running:true}),"atomic save");
assert(fs.stat(path).mode%512==384,"private file mode");
assert(s.load(path).token=="secret","private state available only internally");
let output=s.public_status(s.load(path));
assert(output.running && !output.private_key && !output.token,"whitelisted public status");
fs.symlink(path,path+".link");assert(!s.save(path+".link",{}),"reject symlink overwrite");
assert(!j.valid_request({action:"scan_start",mode:"shell"}),"reject unknown scan mode");
assert(!j.valid_request({action:"register",url:"https://private.invalid"}),"reject unexpected field");
assert(j.valid_request({action:"test_start",duration:15,services:["google"]}),"allowed duration");
assert(!j.live({pid:j.identity().pid,ticks:"0"}),"reused PID rejected");
assert(!j.cancel("absent").success,"cancel cannot target a foreign process");
let restored=false;
let hooks={snapshot:()=>({old:true}),perform:()=>({success:false,error:"test_failure"}),restore:(snapshot)=>{restored=snapshot.old;return true;}};
let r=j.execute({action:"enable"},hooks);
assert(!r.success && r.restored && restored,"failed action restores snapshot");
assert(!s.load(getenv("TRAFIRA_WARP_STATE")+"/active.json"),"successful rollback clears journal");
hooks.restore=()=>false;r=j.execute({action:"enable"},hooks);
assert(!r.success && r.rollback_error && s.load(getenv("TRAFIRA_WARP_STATE")+"/active.json"),"failed recovery retains journal");
fs.writefile(getenv("TRAFIRA_WARP_STATE")+"/active.json","{");
assert(!j.recover(hooks).success,"corrupt journal never treated as no work");
print("WARP state/job checks passed\n");
'

# Exercise the real detached coordinator and global lock with an inert worker.
export TRAFIRA_LIB="$ROOT/trafira/files/usr/lib"
export TRAFIRA_WARP_LIB="$WORK/addon"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK/trafira"
mkdir -p "$TRAFIRA_WARP_LIB/warp" "$TRAFIRA_RUNTIME_STATE_DIR"
cp "$ROOT"/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp/warp/*.uc "$TRAFIRA_WARP_LIB/warp/"
# The corrupt journal from the pure recovery test belongs to its isolated fixture.
export TRAFIRA_WARP_STATE="$WORK/coordinator-state" TRAFIRA_WARP_RUNTIME="$WORK/coordinator-run"
mkdir -p "$TRAFIRA_WARP_STATE" "$TRAFIRA_WARP_RUNTIME"
cat >"$TRAFIRA_WARP_LIB/warp/runtime.uc" <<'UCODE'
let state=require("warp.state"),job=require("warp.job");
function hooks(){return {
 snapshot:()=>({original:true}),
 perform:(request,id)=>{for(let n=0;n<100;n++){if(job.cancelled(id))return {success:false,error:"cancelled"};system("sleep 0.1");}return {success:true};},
 restore:(snapshot)=>state.save(state.RUNTIME+"/recovered.json",{original:snapshot.original})
};}
return {hooks};
UCODE
cli() { ucode -L "$TRAFIRA_LIB" -L "$TRAFIRA_WARP_LIB" "$TRAFIRA_LIB/integrations/warp_cli.uc" action "$1"; }
cli '{"action":"enable"}' >"$WORK/start.json"
python3 - "$WORK/start.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1])); assert v['success'] and v['running'], v
PYTEST
for _ in $(seq 1 30); do
 [ -s "$TRAFIRA_WARP_STATE/active.json" ] && break
 sleep 0.1
done
[ -s "$TRAFIRA_WARP_STATE/active.json" ]
cli '{"action":"disable"}' >"$WORK/busy.json"
python3 - "$WORK/busy.json" <<'PYTEST'
import json,sys
assert json.load(open(sys.argv[1]))['error']=='busy'
PYTEST
id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["job_id"])' "$WORK/start.json")"
cli "{\"action\":\"cancel\",\"job_id\":\"$id\"}" >"$WORK/cancel.json"
for _ in $(seq 1 80); do
 cli '{"action":"job_status"}' >"$WORK/status.json"
 python3 -c 'import json,sys;sys.exit(bool(json.load(open(sys.argv[1]))["running"]))' "$WORK/status.json" && break
 sleep 0.1
done
python3 - "$WORK/status.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1]));assert not v['running'] and v['error']=='cancelled' and v['restored'], v
PYTEST
[ ! -e "$TRAFIRA_WARP_STATE/active.json" ]
echo 'WARP detached coordinator, busy lock and cancellation checks passed'

# A killed coordinator leaves its durable journal; the next action recovers it.
cli '{"action":"enable"}' >"$WORK/second.json"
for _ in $(seq 1 40); do
 [ -s "$TRAFIRA_WARP_STATE/active.json" ] && break
 sleep 0.1
done
worker="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["worker"]["pid"])' "$TRAFIRA_WARP_RUNTIME/job.json")"
kill -KILL "$worker"
for _ in $(seq 1 40); do
 cli '{"action":"job_status"}' >"$WORK/interrupted.json"
 python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("error")!="worker_interrupted")' "$WORK/interrupted.json" && break
 sleep 0.1
done
[ -s "$TRAFIRA_WARP_STATE/active.json" ]
cli '{"action":"enable"}' >"$WORK/restarted.json"
python3 - "$WORK/restarted.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1]));assert v['success'],v
PYTEST
for _ in $(seq 1 80); do
 [ -s "$TRAFIRA_WARP_RUNTIME/recovered.json" ] && break
 sleep 0.1
done
id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["job_id"])' "$WORK/restarted.json")"
cli "{\"action\":\"cancel\",\"job_id\":\"$id\"}" >"$WORK/cancel-restarted.json"
for _ in $(seq 1 80); do
 cli '{"action":"job_status"}' >"$WORK/recovered-status.json"
 python3 -c 'import json,sys;sys.exit(bool(json.load(open(sys.argv[1]))["running"]))' "$WORK/recovered-status.json" && break
 sleep 0.1
done
python3 - "$WORK/recovered-status.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1]));assert not v['running'] and v['restored'],v
PYTEST
echo 'WARP SIGKILL recovery checks passed'
