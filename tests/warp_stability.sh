#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let s=require("warp.stability");
assert(!s.valid_address("198.18.0.1") && !s.valid_address("127.0.0.1") && !s.valid_address("10.0.0.1"),"no FakeIP or local address probes");
assert(s.valid_address("1.1.1.1"),"real public address accepted");
let summary=s.summarize([{service:"chatgpt",code:403,total:0.1,success:true},{service:"chatgpt",code:429,total:0.2,success:true},{service:"google",code:204,total:0.3,success:true},{service:"google",code:0,total:8,success:false,error:"timeout"}]);
assert(summary.samples==4 && summary.transport_errors==1,"403 and429 differ from transport failures");
assert(summary.http_restricted==2 && summary.median==0.2 && summary.p95==0.3,"successful transport timing statistics");
assert(!s.valid_request(10,["google"]) && !s.valid_request(15,["http://localhost/"]),"bounded catalogue only");
assert(s.valid_request(15,["google","chatgpt"]),"supported duration andservices");
assert(!s.valid_request(15,["google","google"]),"duplicate probes rejected");
print("WARP stability checks passed\n");
'
