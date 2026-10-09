#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_PROFILES_DIR="$WORK_DIR/profiles"
export TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_CONFIG_FILE="$WORK_DIR/current"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf original >"$TRAFIRA_CONFIG_FILE"
cat >"$TRAFIRA_LIB/config/profile_runtime.uc" <<'UC'
let fs=require("fs"),format=require("config.profile_format");
return {
 prepare:(document,directory)=>{fs.writefile(directory+"/trafira",format.to_uci(document.config));return {success:true,path:directory+"/trafira"};},
 hooks:()=>({validate:()=>true,capture:()=>({running:true,enabled:false}),activate:()=>{system("sleep 2");return true;},restore:()=>true})
};
UC
profile=$(ucode -L "$TRAFIRA_LIB" -e 'let p=require("config.profiles"); print(p.create({schema:1,name:"Job",config:[{".name":"settings",".type":"settings",password:"private"}]}).id);')
digest=$(sha256sum "$TRAFIRA_CONFIG_FILE" | cut -d' ' -f1)
call() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/profile_cli.uc" action "$1"; }
call "{\"action\":\"apply\",\"id\":\"$profile\",\"digest\":\"$digest\"}" >"$WORK_DIR/start.json"
call "{\"action\":\"apply\",\"id\":\"$profile\",\"digest\":\"$digest\"}" >"$WORK_DIR/duplicate.json"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),p=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${p}/${n}.json`));
if (!read('start').success || !read('start').job_id || read('duplicate').success) throw Error('job launch or duplicate guard');
JS
for _ in $(seq 1 20); do
  call '{"action":"status"}' >"$WORK_DIR/status.json"
  if node - "$WORK_DIR/status.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2]));process.exit(r.running?1:0);
JS
  then break; fi
  sleep 1
done
node - "$WORK_DIR/status.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2]));
if (!r.success || r.running || JSON.stringify(r).includes('private')) throw Error('job did not finish safely after launcher exited');
JS
grep -q private "$TRAFIRA_CONFIG_FILE"
test "$(cat "$TRAFIRA_TRANSACTION_DIR/previous.uci")" = original
ucode -L "$TRAFIRA_LIB" -e '
let fs=require("fs"),job=require("config.profile_job"),h=require("singbox.provenance");
let root=getenv("TRAFIRA_RUNTIME_STATE_DIR")+"/profile-work",work=job.new_directory();
fs.writefile(work.directory+"/request.json",sprintf("%J",{recover:true,digest:h.hash_file(getenv("TRAFIRA_CONFIG_FILE"))}));
fs.writefile(root+"/job.json",sprintf("%J",{running:true,job_id:work.id,started_at:clock()[0]}));
fs.writefile(getenv("TRAFIRA_CONFIG_FILE"),"concurrent edit");
let result=job.worker(work.id);
assert(!result.success && result.error=="conflict","queued recovery checks digest again after taking its lock");
assert(fs.readfile(getenv("TRAFIRA_CONFIG_FILE"))=="concurrent edit","concurrent edit preserved");
'
printf 'background profile apply checks passed\n'
