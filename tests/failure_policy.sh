#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let p=require("singbox.failure_policy");
let policy={mode:"direct",failures:3,recoveries:2,hold_seconds:30};
let state=null;
state=p.step(state,{primary:"unknown",reserve:"unknown"},100,policy).state;
assert(state.mode=="blocked" && state.monitor_error,"strict policy starts blocked");
state=p.step(state,{primary:"up"},101,policy).state;
assert(state.mode=="blocked","one recovery sample insufficient");
state=p.step(state,{primary:"up"},102,policy).state;
assert(state.mode=="primary","initial health proof opens primary without waiting for a failure hold");
for(let now in [103,104,105])state=p.step(state,{primary:"down"},now,policy).state;
assert(state.mode=="primary","hold prevents flapping");
state=p.step(state,{primary:"unknown"},130,policy).state;
assert(state.fail_count==0 && state.monitor_error,"API errors do not confirm outage");
for(let now in [131,132,133])state=p.step(state,{primary:"down"},now,policy).state;
assert(state.mode=="direct","only explicit direct policy permits fallback after threshold");
for(let now in [163,164])state=p.step(state,{primary:"up"},now,policy).state;
assert(state.mode=="primary","confirmed recovery returns to primary");
state=p.step(state,{primary:"unknown"},50,policy).state;
assert(state.mode=="blocked","monotonic clock reset invalidates previous runtime state");
let reserve={...policy,mode:"reserve",reserve_section:"backup"};
state={mode:"reserve",fail_count:3,success_count:0,last_transition:200,observed_at:200};
state=p.step(state,{primary:"down",reserve:"down"},201,reserve).state;
assert(state.mode=="blocked","reserve outage blocks immediately even inside hold");
state=p.step(null,{primary:"down",reserve:"up"},300,{...policy,mode:"block"}).state;
assert(state.mode=="blocked","block never selects reserve or direct");
assert(p.step(null,{primary:"down"},300,{mode:"legacy"}).transition==null,"legacy remains unmanaged");
assert(!p.valid({...policy,failures:0}) && !p.valid({...policy,recoveries:11}) && !p.valid({...policy,hold_seconds:29}),"policy bounds");
assert(length(p.validate_sections([
 {".name":"a",enabled:"1",action:"proxy",failure_policy:"reserve",failure_reserve_section:"b"},
 {".name":"b",enabled:"1",action:"proxy",outbound_detour_enabled:"1",outbound_detour_section:"a"}
]))>0,"reserve and detour cycles rejected together");
assert(length(p.validate_sections([
 {".name":"a",enabled:"1",action:"proxy",failure_policy:"reserve",failure_reserve_section:"missing"}
]))>0,"missing reserve rejected");
print("failure policy state machine checks passed\n");
'
