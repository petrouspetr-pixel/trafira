#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let r=require("config.router_origin");
let sections=[{".name":"vpn",action:"connection",enabled:"1"}];
assert(!r.config({},sections).enabled,"default off");
let settings={router_origin_enabled:"1",router_origin_section:"vpn"};
assert(r.config(settings,sections).enabled && !r.config(settings,sections).error,"enabled target valid");
assert(r.config({...settings,router_origin_section:"absent"},sections).error,"missing target cannot fall back to direct");
assert(r.config(settings,[{...sections[0],enabled:"0"}]).error,"disabled target rejected");
assert(r.config(settings,sections,{fakeip_mark:"0x10000000"}).error,"mark collision rejected");
assert(r.config(settings,sections,{mwan3_mask:"0x10000000"}).error,"mwan3 collision rejected");
let c={inbounds:[],outbounds:[{tag:"vpn-out",type:"direct"}],route:{rules:[{action:"sniff",inbound:["tproxy-in"]},{action:"hijack-dns",protocol:"dns"},{action:"route",protocol:"bittorrent",outbound:"bypass-out"}]},dns:{rules:[]}};
r.attach(c,settings,sections);
assert(length(c.inbounds)==2 && c.inbounds[0].listen_port==1605,"distinct dual stack listeners");
assert(c.route.rules[2].inbound[0]=="router-tproxy-in" && c.route.rules[2].outbound=="vpn-out","router route precedes LAN torrent and Alice rules");
assert(c.dns.rules[0].inbound[1]=="router-tproxy6-in","router DNS identified independently");
let n=r.nft("Test", "localv4", "localv6", "0x04000000", {dns:["192.0.2.53"],ntp:["2001:db8::123"],vpn:[{ip:"192.0.2.9",port:51820}],vpn_ports:[32000]});
assert(n && index(n,"ct direction reply return")>=0,"management response exclusion");
assert(index(n,"ct state established")<0,"subsequent original packets remain captured");
assert(index(n,"udp dport 123 return")<0,"NTP bypass scoped to destinations");
assert(index(n,"meta mark != 0 return")>=0,"existing explicit transports retain precedence");
assert(index(n,"0x14000000")>=0 && index(n,"1605")>=0,"combined mark and router listener");
assert(!r.nft("bad; table", "localv4", "localv6", "0x04000000", {}),"nft identifiers sanitized");
print("router origin checks passed\n");
'
