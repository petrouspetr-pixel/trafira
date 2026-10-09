#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let a=require("service.failure_policy_apply"),events=[],fail="",generation="g1";
function stage(name){push(events,name);return fail!=name;}
let hooks={generation:()=>generation,prepare:()=>stage("prepare"),guard:()=>stage("guard"),
 install:()=>stage("install"),reload:()=>stage("reload"),healthy:()=>stage("healthy"),
 publish:()=>stage("publish"),unguard:()=>stage("unguard"),restore:()=>stage("restore")};
assert(a.transition("g1",hooks).success,"verified transition");
assert(join(",",events)=="prepare,guard,install,reload,healthy,publish,unguard","guard precedes mutation and outlives health/publication");
for(let fault in ["install","reload","healthy","publish"]) {
 events=[];fail=fault;
 let result=a.transition("g1",hooks);
 assert(!result.success && result.guarded && index(events,"unguard")<0 && index(events,"restore")>=0,"failure retains guard: "+fault);
}
events=[];fail="guard";
assert(!a.transition("g1",hooks).success && index(events,"install")<0,"guard failure prevents mutation");
events=[];fail="";generation="edited";
assert(a.transition("g1",hooks).error=="conflict" && length(events)==0,"stale generation rejected");
generation="g1";hooks.prepare=()=>{generation="g2";return true;};events=[];
assert(a.transition("g1",hooks).error=="conflict" && index(events,"guard")<0,"late generation edit rejected");
let rules=a.guard_script([1602,1603,1604,8080]);
assert(index(rules,"meta mark & 0x04000000 != 0 counter drop")>=0 && index(rules,"table inet TrafiraFailureGuard")>=0,"guard covers both address families with existing capture mark");
assert(index(rules,"hook input")>=0 && index(rules,"8080")>=0,"bound proxy/server ports guarded");
print("failure policy guarded transaction checks passed\n");
'
