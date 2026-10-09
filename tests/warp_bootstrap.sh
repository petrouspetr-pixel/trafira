#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/trafira/files/usr/lib" -e '
let r=require("nft.router_origin"),t=require("integrations.warp_transport");
let live={schema:1,owner:"trafira-warp",interface:"tfwarp0",endpoint:"162.159.192.1:2408",listen_port:32000,fwmark:134217728,running:true};
let result={vpn:[],vpn_ports:[]},known={};
assert(t.valid(live),"verified private transport shape");
assert(r.include_warp(result,known,live) && known.tfwarp0,"userspace transport recognized");
assert(!length(result.vpn) && !length(result.vpn_ports),"ordinary UDP to same peer gets no new exception");
let script=require("config.router_origin").nft("Test","local4","local6","0x04000000",result);
assert(script && index(script,"162.159.192.1")<0 && index(script,"32000")<0,"only existing transport mark exemption");
assert(!r.include_warp({}, {}, {...live,fwmark:67108864}),"capture mark rejected");
assert(r.include_warp({vpn:[],vpn_ports:[]},{},{schema:1,owner:"trafira-warp",interface:"tfwarp0",running:false,configured:true}),"verified inactive owned WARP permits fail-closed core reload");
assert(!r.include_warp({}, {}, {schema:1,owner:"trafira-warp",interface:"wan",running:false,configured:true}),"inactive foreign interface rejected");
print("WARP router-origin ownership and mark isolation passed\n");
'
