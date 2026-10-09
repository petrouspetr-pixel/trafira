#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let p=require("singbox.failure_config");
let section={".name":"vpn",action:"connection",failure_policy:"block"};
let base={outbounds:[{type:"direct",tag:"vpn-out"},{type:"direct",tag:"backup-out"}],
 route:{final:"direct-out",rules:[
  {action:"route",source_ip_cidr:["192.0.2.1/32","2001:db8::1/128"],domain_suffix:["example.test"],outbound:"vpn-out",__trafira_origin:{section:"vpn"}},
  {action:"route",inbound:"vpn-mixed-in",outbound:"vpn-out"},
  {action:"route",inbound:"unrelated",outbound:"direct-out"}
 ]},dns:{servers:[{tag:"dns-server",type:"https",server:"192.0.2.53"},{tag:"fakeip-server",type:"fakeip"}],rules:[
  {action:"route",domain_suffix:["example.test"],server:"dns-server",__trafira_origin:{section:"vpn"}},
  {action:"route",domain_suffix:["fake.test"],server:"fakeip-server",__trafira_origin:{section:"vpn"}}
 ]}};
let blocked=p.apply(base,[section],{});
assert(blocked.route.rules[0].action=="reject" && blocked.route.rules[0].outbound==null,"strict cold start blocks");
assert(length(blocked.route.rules[0].source_ip_cidr)==2 && blocked.route.rules[0].domain_suffix[0]=="example.test","IPv4/IPv6 and destination matchers retained");
assert(blocked.route.rules[1].action=="reject" && blocked.route.rules[2].outbound=="direct-out","mixed inbound covered; unrelated route untouched");
assert(blocked.dns.rules[0].action=="reject" && blocked.dns.rules[0].server==null,"blocked DNS cannot use direct resolver");
let direct=p.apply(base,[{...section,failure_policy:"direct"}],{vpn:{mode:"direct"}});
assert(direct.route.rules[0].outbound=="bypass-out","direct explicitly enabled");
let reserve=p.apply(base,[{...section,failure_policy:"reserve",failure_reserve_section:"backup"}],{vpn:{mode:"reserve"}});
assert(reserve.route.rules[0].outbound=="backup-out","reserve selected");
assert(reserve.dns.servers[2].detour=="backup-out","user DNS follows selected protected path");
assert(reserve.dns.rules[1].server=="fakeip-server","FakeIP allocation is local");
let primary=p.apply(base,[section],{vpn:{mode:"primary"}});
assert(primary.route.rules[0].outbound=="vpn-out" && primary.dns.servers[2].detour=="vpn-out","primary DNS protected");
assert(base.route.rules[0].action=="route" && length(base.dns.servers)==2,"baseline never mutated");
assert(p.apply(base,[{...section,failure_policy:"legacy"}],{}).route.rules[0].outbound=="vpn-out","legacy unchanged");
let unknown=json(sprintf("%J",base));
unknown.dns.rules[0].server="absent";
assert(p.apply(unknown,[section],{vpn:{mode:"primary"}}).dns.rules[0].action=="reject","unknown DNS resolver is never left unprotected");
let response=json(sprintf("%J",base));
response.dns.rules=[{action:"evaluate",server:"dns-server",__trafira_origin:{section:"vpn"}},{action:"route",match_response:true,rule_set:"addresses",server:"fakeip-server",__trafira_origin:{section:"vpn"}}];
let protected=p.apply(response,[section],{vpn:{mode:"primary"}});
assert(protected.dns.rules[0].action=="evaluate" && protected.dns.servers[2].detour=="vpn-out","address evaluation stays on protected DNS");
assert(p.apply(response,[section],{}).dns.rules[0].action=="reject","cold address evaluation fails closed before any DNS lookup");
print("failure policy configuration checks passed\n");
'
