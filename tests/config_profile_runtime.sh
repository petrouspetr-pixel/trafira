#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export PROFILE_TEST_DIR="$WORK_DIR"
export PATH="$WORK_DIR/bin:$PATH"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stage" "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'sing-box version 1.14.0'; exit 0; fi
printf '%s\n' "$*" >>"$PROFILE_TEST_DIR/checks"
[ ! -e "$PROFILE_TEST_DIR/reject-check" ]
SH
chmod +x "$WORK_DIR/bin/sing-box"
cat >"$WORK_DIR/candidate-core" <<'SH'
#!/bin/sh
printf '%s\n' "$LD_LIBRARY_PATH $*" >"$PROFILE_TEST_DIR/candidate-check"
[ ! -e "$PROFILE_TEST_DIR/reject-candidate" ]
SH
chmod +x "$WORK_DIR/candidate-core"
ucode -L "$TRAFIRA_LIB" -e '
let fs=require("fs"),r=require("config.profile_runtime"),f=require("config.profile_format");
let directory=getenv("PROFILE_TEST_DIR")+"/stage";
let document={schema:1,name:"Test",config:[
 {".name":"settings",".type":"settings",dns_type:"udp",dns_server:["1.1.1.1"],bootstrap_dns_server:["1.1.1.1"]},
 {".name":"direct",".type":"section",enabled:"1",action:"bypass",domain_suffix:["example.org"]}
]};
let prepared=r.prepare(document,directory);
assert(prepared.success,"prepare isolated candidate");
let hooks=r.hooks(document,directory);
assert(hooks.validate(prepared.path),"candidate generated and checked");
assert(fs.readfile(prepared.path)==f.to_uci(document.config),"candidate preserved");
assert(fs.stat(getenv("PROFILE_TEST_DIR")+"/checks"),"real check command invoked");
fs.writefile(getenv("PROFILE_TEST_DIR")+"/reject-check","1");
assert(!hooks.validate(prepared.path),"core rejection propagates");
fs.unlink(getenv("PROFILE_TEST_DIR")+"/reject-check");
assert(!r.dependencies({outbounds:[{bind_interface:"missing-trafira-test"}]}),"missing interface rejected");
assert(!r.dependencies({dns:{servers:[{tls:{client_key_path:"/missing-trafira-key"}}]}}),"missing key rejected");
assert(r.dependencies({outbounds:[{bind_interface:"lo"}]}),"existing interface accepted");
let core={binary:getenv("PROFILE_TEST_DIR")+"/candidate-core",library_path:directory,version:"1.14.0",variant:"stable"};
let candidate_hooks=r.hooks(document,directory,core);
assert(candidate_hooks.validate(prepared.path) && index(fs.readfile(getenv("PROFILE_TEST_DIR")+"/candidate-check")||"",directory)>=0,"selected candidate checked with staged libraries");
fs.writefile(getenv("PROFILE_TEST_DIR")+"/reject-candidate","1");
assert(!candidate_hooks.validate(prepared.path),"candidate failure cannot fall back to installed core");
let g=require("config.gaming_presets"),matcher=require("diagnostics.route_match");
let built=g.build({id:"steam",revision:1,domains:[{value:"store.example",match:"exact"}]},{device_ips:["192.0.2.5/32","2001:db8::5/128"],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"},{digest:"test",devices:[{interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]}],sections:[document.config[0],{".name":"vpn",".type":"section",enabled:"1",action:"connection",outbound_jsons:["{\"type\":\"socks\",\"tag\":\"vpn-leaf\",\"server\":\"192.0.2.9\",\"server_port\":1080}"]}]});
assert(built.valid,"gaming builder");
let gaming={schema:1,name:"Gaming",config:built.config},stage=r.prepare(gaming,directory);
assert(stage.success && r.hooks(gaming,directory).validate(stage.path),"gaming candidate validated and generated");
let generated=json(fs.readfile(directory+"/sing-box.json"));
let storetag=built.owner+"-out", wrappers=filter(generated.outbounds,(o)=>o.type=="selector" && index(o.outbounds||[],"vpn-out")>=0);
assert(length(wrappers)>0,"store selector actually targets VPN, not excluded JSON cascade");
for(let address in ["192.0.2.5","2001:db8::5"]) {
 let req={source_ip:address,domain:"store.example",inbound:"tproxy-in",protocol:"tls",network:"tcp",port:443,destination_ip:"203.0.113.20"};
 let store=matcher.explain(generated,req,{},{}),other=matcher.explain(generated,{...req,domain:"play.example"},{},{});
 assert(store.status=="matched" && store.outbound==built.owner+"_store-out",sprintf("store route %J",store));
 assert(other.outbound=="bypass-out","remaining selected device direct");
 assert(matcher.explain(generated,{...req,source_ip:"192.0.2.6"},{},{}).outbound!=store.outbound,"other device excluded");
 let dns={...generated,route:{rules:generated.dns.rules,final:generated.dns.final}};
 assert(matcher.explain(dns,req,{},{}).status!="indeterminate","source-scoped store DNS is evaluable");
}
fs.writefile(prepared.path,"changed");
assert(!hooks.validate(prepared.path),"tampered candidate rejected");
'
test "$(stat -c %a "$WORK_DIR/stage/trafira")" = 600
printf 'profile candidate runtime checks passed\n'
