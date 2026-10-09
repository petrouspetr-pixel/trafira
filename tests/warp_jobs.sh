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
assert(s.load(path).token=="secret","private state available only internally");
let output=s.public_status(s.load(path));
assert(output.running && !output.private_key && !output.token,"whitelisted public status");
fs.symlink(path,path+".link");assert(!s.save(path+".link",{}),"reject symlink overwrite");
assert(!j.valid_request({action:"scan_start",mode:"shell"}),"reject unknown scan mode");
assert(!j.valid_request({action:"register",url:"https://private.invalid"}),"reject unexpected field");
assert(j.valid_request({action:"test_start",duration:15,services:["google"]}),"allowed duration");
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
