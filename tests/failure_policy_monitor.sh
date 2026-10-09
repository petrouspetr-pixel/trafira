#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let m=require("singbox.failure_monitor");
let proxies={"vpn-out":{now:"node"},node:{type:"Socks"}};
assert(m.sample(null,null,"vpn-out").health=="unknown","API outage remains unknown");
assert(m.sample({message:"Timeout"},proxies,"missing").health=="down","removed outbound confirmed from current API snapshot");
assert(m.sample({message:"Timeout"},proxies,"vpn-out").health=="down","known tunnel timeout");
assert(m.sample({message:"Unauthorized"},proxies,"vpn-out").health=="unknown","authentication failure not a tunnel outage");
assert(m.sample({delay:15},proxies,"vpn-out").health=="up","valid delay confirms health");
assert(m.sample({delay:15},proxies,"vpn-out").selected=="node","actual primary selector observed");
let section={".name":"vpn",failure_policy:"direct",failure_threshold:"1",recovery_threshold:"1",failure_hold_seconds:"30"};
let previous={mode:"primary",observed_at:100,last_transition:50,initialized:true,selected:"old",fail_count:0,success_count:0};
let next=m.observe(section,previous,{health:"unknown",selected:"new"},{health:"unknown"},101);
assert(next.state.mode=="blocked" && next.changed,"manual selection re-enters health verification");
assert(next.state.selected=="new" && next.state.fail_count==0,"manual selection resets counters without disabling policy");
next=m.observe(section,{...previous,selected:"node"},{health:"unknown",selected:"node"},{health:"unknown"},101);
assert(next.state.mode=="primary" && !next.changed && next.state.monitor_error,"API error never silently enables direct");
let deep={};for(let n=0;n<35;n++)deep["n"+n]={now:"n"+(n+1)};
assert(m.sample({delay:1},deep,"n0").health=="unknown","unresolved selector chain is not healthy");
print("failure policy monitor evidence checks passed\n");
'
