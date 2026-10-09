#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let w=require("warp.watchdog"),s={enabled:true,running:true,generation:2},v={};
for(let n=0;n<3;n++)v=w.decide(v,s,false,100+n*30);
assert(v.reconnect && v.attempts==1,"live unhealthy transport gets bounded recovery");
let later=w.decide(v,s,false,170);assert(!later.reconnect,"backoff respected");
v=w.decide(v,s,false,500);assert(v.reconnect && v.attempts==2,"second retry");
v=w.decide(v,s,false,1000);assert(v.reconnect && v.attempts==3,"third retry");
v=w.decide(v,s,false,2000);assert(!v.reconnect && v.exhausted,"bounded recovery stops repeated flash writes");
v=w.decide(v,s,true,2100);assert(!v.exhausted && v.attempts==0,"verified health resets budget");
v=w.decide(v,{enabled:false,running:false},false,2200);assert(!v.reconnect,"disabled tunnel never restarted");
print("WARP watchdog backoff, live-health and exhausted budget passed\n");
'
