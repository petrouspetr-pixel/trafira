#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let t=require("warp.transport");
let foreign={tfwarp0:{proto:"none"}},devices=["tfwarp0"];
assert(t.choose_interface(foreign,devices)=="tfwarp1","never overwrite foreign interface");
for(let n=0;n<10;n++)foreign["tfwarp"+n]={proto:"none"};
assert(t.choose_interface(foreign,[])==null,"no free slot fails closed");
assert(t.valid_endpoint("162.159.192.1:2408"),"IPv4 endpoint accepted");
assert(!t.valid_endpoint("127.0.0.1:2408") && !t.valid_endpoint("198.18.0.1:2408"),"reject local/FakeIP endpoint");
assert(!t.valid_endpoint("example.org:2408") && !t.valid_endpoint("162.159.192.1:0"),"numeric validated endpoint only");
assert(!t.valid_config({endpoint:"162.159.192.1:2408",fwmark:67108864}),"capture mark rejected");
let config={interface:"tfwarp0",endpoint:"162.159.192.1:2408",fwmark:134217728,mtu:1280,
 ipv4:"172.16.0.2",ipv6:"2606:4700:110:8::2",private_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",peer_public_key:"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",jc:5,jmin:10,jmax:50,i1:"<b 0x01>"};
assert(t.valid_config(config),"valid owned candidate");
let args=t.address_commands(config,false);assert(length(args)==1 && args[0][0]=="ip","IPv6 disabled adds only IPv4");
let commands=t.address_commands(config,true);assert(length(commands)==2,"IPv6 configured when available");
assert(t.network_section("tfwarp0").defaultroute=="0" && t.network_section("tfwarp0").peerdns=="0","no global route or DNS");
assert(t.routing_identity("tfwarp0").table!=t.routing_identity("tfwarp1").table,"isolated slot tables");
assert(!t.routing_identity("wan"),"no policy table for foreign interfaces");
print("WARP transport validation checks passed\n");
'
