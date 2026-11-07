#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let b=require("singbox.ruleset_bootstrap");
let config={dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"192.0.2.53",server_port:5353,detour:"production"}]},
 outbounds:[{type:"socks",tag:"production",server:"unavailable.invalid",server_port:1080}],
 route:{final:"production",default_mark:134217728,auto_detect_interface:true,rule_set:[{type:"remote",tag:"list",format:"source",url:"https://cold-list.invalid/rules.json",http_client:{}}]}};
let before=sprintf("%J",config),plan=b.plan(config);
assert(length(plan.candidates)==1 && plan.candidates[0]=="","direct is explicit, never a production selector fallback");
let stage=b.stage(config,"",4539,{username:"fixture",password:"fixture"});
assert(stage.error==null,"direct bootstrap needs an independent resolver even before the main core starts");
assert(length(stage.outbounds)==1 && stage.outbounds[0].type=="direct" && stage.route.final==stage.outbounds[0].tag,"private direct route must not inherit the production AWG route");
assert(stage.route.default_domain_resolver=="bootstrap-dns-server" && stage.dns.servers[0].server=="192.0.2.53" && stage.dns.servers[0].server_port==5353,"use the configured IP resolver and port");
assert(stage.dns.servers[0].detour==null && stage.dns.servers[0].domain_resolver==null,"resolver must not depend on production routing or DNS");
assert(stage.route.default_mark==config.route.default_mark && stage.route.auto_detect_interface===true,"retain configured routing marks and interface policy");
assert(length(stage.route.rule_set)==0 && length(stage.route.rules)==0 && stage.experimental==null && stage.endpoints==null,"no lists, API, cache or endpoint side effects");
assert(stage.inbounds[0].listen=="127.0.0.1" && stage.inbounds[0].users[0].username=="fixture","only an authenticated loopback listener");
assert(sprintf("%J",config)==before,"preparation must not mutate the main configuration");
delete config.dns;
assert(b.stage(config,"",4539).error!=null,"missing independent DNS must fail closed, not use the stopped main resolver");
print("Direct bootstrap has independent DNS and no production-route dependencies\n");
'
