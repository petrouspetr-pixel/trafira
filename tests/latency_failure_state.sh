#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ucode -L "$TRAFIRA_LIB" -e '
let probe=require("diagnostics.latency"),fs=require("fs"),path=ARGV[0];
assert(probe.valid({delay:12},false),"positive delay");
assert(!probe.valid({message:"Timeout"},false),"JSON timeout is not success");
assert(!probe.valid({delay:0},false),"zero delay means unavailable");
assert(!probe.valid({delay:-1},false),"negative delay invalid");
assert(!probe.valid({delay:"12"},false),"string is not a measurement");
assert(probe.valid({node:12},true),"group results");
assert(probe.valid({},true),"concurrent URLTest has no new measurements, not a failure");
assert(!probe.valid({message:"Timeout"},true),"group JSON timeout");
let proxies={node:{type:"Direct",history:[]},other:{type:"Direct",history:[]}};
probe.apply(proxies,path,"core1/config1");
assert(!proxies.node.trafira_latency_failed,"never checked");
assert(probe.record(path,"core1/config1","node",true),"record first failed probe");
probe.apply(proxies,path,"core1/config1");
assert(proxies.node.trafira_latency_failed,"first failure survives a fresh API read/browser reload");
assert(!proxies.other.trafira_latency_failed,"unrelated node unchanged");
probe.apply(proxies,path,"core2/config1");
assert(!proxies.node.trafira_latency_failed,"restart invalidates old failure");
probe.apply(proxies,path,"core1/config2");
assert(!proxies.node.trafira_latency_failed,"configuration change invalidates old failure");
probe.record(path,"core1/config1","node",false);
probe.apply(proxies,path,"core1/config1");
assert(!proxies.node.trafira_latency_failed,"successful retry clears failure");
probe.record(path,"core1/config1","node",true);
proxies.node.history=[{delay:30}];
probe.apply(proxies,path,"core1/config1");
assert(!proxies.node.trafira_latency_failed,"fresh core history takes precedence");
assert(!probe.record(path,"","node",true),"unknown core cannot save misleading failure");
for(let i=0;i<160;i++)probe.record(path,"bounded","node"+i,true);
let stored=json(fs.readfile(path));
assert(length(keys(stored.failed))<=128 && fs.stat(path).size<65536,"bounded RAM cache");
fs.writefile(path,"invalid JSON");
probe.apply(proxies,path,"core1/config1");
assert(!proxies.node.trafira_latency_failed,"corrupt cache ignored");
' "$WORK_DIR/failures.json"
printf 'Explicit latency failures, recovery, core/config scope and RAM bounds passed\n'
