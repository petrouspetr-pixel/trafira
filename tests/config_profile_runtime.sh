#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export PROFILE_TEST_DIR="$WORK_DIR"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/snapshots"
export PATH="$WORK_DIR/bin:$PATH"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stage" "$TRAFIRA_RUNTIME_STATE_DIR"
mkdir -p "$TRAFIRA_RULESET_CACHE_DIR"
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
// A warm startup cache must not trigger a core process per list in preview.
// The final configuration check and normal startup snapshot validation remain.
let cache=require("singbox.ruleset_cache"),url="https://example.org/profile-regression.srs";
let snapshot=cache.path({type:"remote",url,format:"binary"});
fs.writefile(snapshot,"snapshot");
let cached=json(sprintf("%J",document));cached.config[1].rule_set=[url];
let cached_stage=r.prepare(cached,directory);
fs.writefile(getenv("PROFILE_TEST_DIR")+"/checks","");
assert(cached_stage.success && r.hooks(cached,directory).validate(cached_stage.path),"cached profile still passes core check");
let cached_config=json(fs.readfile(directory+"/sing-box.json"));
assert(!filter(cached_config.route.rule_set,(rule)=>rule.initial_path)[0],"candidate check excludes startup snapshots");
let calls=fs.readfile(getenv("PROFILE_TEST_DIR")+"/checks")||"";
assert(index(calls,"rule-set")<0 && index(calls," check")>=0,"one final core check without snapshot decompilation");
fs.writefile(getenv("PROFILE_TEST_DIR")+"/reject-check","1");
assert(!r.hooks(cached,directory).validate(cached_stage.path),"cached profile cannot bypass core rejection");
fs.unlink(getenv("PROFILE_TEST_DIR")+"/reject-check");
let lib=getenv("TRAFIRA_LIB"),normal=directory+"/startup.json";
assert(system(sprintf("ucode -L %s %s/singbox/generator.uc generate-config-fixture %s/fixture.json %s 127.0.0.1 0 1 %s 1.14.0",lib,lib,directory,normal,"\x27\x27"))==0,"normal startup generation");
assert(filter(json(fs.readfile(normal)).route.rule_set,(rule)=>rule.initial_path==snapshot)[0],"normal startup stages snapshots without unbounded validation");
assert(require("singbox.ruleset_bootstrap").prepare_file(normal,"1.14.0"),"startup validates snapshots inside its supervised budget");
assert(index(fs.readfile(getenv("PROFILE_TEST_DIR")+"/checks"),"rule-set decompile")>=0,"startup still invokes snapshot validator");
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
 assert(matcher.explain(dns,{...req,inbound:require("singbox.constants").SOURCE_DNS_INBOUND_TAG,query_type:"A"},{},{}).outbound=="fakeip-server","source-scoped store DNS receives FakeIP");
}
// Legacy interleaved presets are repaired by generation without modifying saved UCI.
let epic=g.build({id:"epic",revision:1,domains:[{value:"epic.example",match:"suffix"}]},{device_ips:["192.0.2.5/32","2001:db8::5/128"],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"},{digest:"test",devices:[{interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]}],sections:built.config});
assert(epic.valid,"second gaming platform");
let manual={".name":"manual",".type":"section",action:"bypass",enabled:"1",fully_routed_ips:["192.0.2.5/32","2001:db8::5/128"]};
let legacy={schema:1,name:"Legacy gaming",config:[gaming.config[0],...built.patch.sections,manual,...epic.patch.sections,filter(built.config,(s)=>s[".name"]=="vpn")[0]]};
let saved=sprintf("%J",legacy);
let generated_legacy=r.prepare(legacy,directory);
assert(generated_legacy.success && r.hooks(legacy,directory).validate(generated_legacy.path),"legacy gaming generated");
assert(sprintf("%J",legacy)==saved,"generator leaves source UCI unchanged");
let combined=json(fs.readfile(directory+"/sing-box.json"));
for(let address in ["192.0.2.5","2001:db8::5"]){
 let req={source_ip:address,domain:"store.example",inbound:"tproxy-in",protocol:"tls",network:"tcp",port:443,destination_ip:"203.0.113.20"};
 assert(matcher.explain(combined,req,{},{}).outbound==built.owner+"_store-out","Steam store still proxied");
 assert(matcher.explain(combined,{...req,domain:"cdn.epic.example"},{},{}).outbound==epic.owner+"_store-out","Epic store precedes Steam direct and manual fallback for both families");
 assert(matcher.explain(combined,{...req,domain:"unrelated.example"},{},{}).outbound=="bypass-out","other game traffic direct");
}
let disabled=json(saved);for(let section in disabled.config)if(section[".name"]==epic.owner+"_store")section.enabled="0";
let disabled_stage=r.prepare(disabled,directory);
assert(disabled_stage.success && r.hooks(disabled,directory).validate(disabled_stage.path),"disabled preset generation");
assert(matcher.explain(json(fs.readfile(directory+"/sing-box.json")),{source_ip:"192.0.2.5",domain:"cdn.epic.example",inbound:"tproxy-in",protocol:"tls",network:"tcp",port:443,destination_ip:"203.0.113.20"},{},{}).outbound=="bypass-out","disabled store is never reenabled by normalization");
let remaining=g.remove(built.owner,"delete",false,{sections:legacy.config});
let remaining_doc={schema:1,name:"Remaining gaming",config:remaining.config},remaining_stage=r.prepare(remaining_doc,directory);
assert(remaining.valid && remaining_stage.success && r.hooks(remaining_doc,directory).validate(remaining_stage.path),"remaining preset generated");
// Manual priority intentionally remains where the user placed it when Steam is removed.
let independent=g.build({id:"epic",revision:1,domains:[{value:"epic.example",match:"suffix"}]},{device_ips:["192.0.2.5/32","2001:db8::5/128"],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"},{digest:"test",devices:[{interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]}],sections:remaining.config});
let independent_doc={schema:1,name:"Independent gaming",config:independent.config},independent_stage=r.prepare(independent_doc,directory);
assert(independent_stage.success && r.hooks(independent_doc,directory).validate(independent_stage.path),"remaining preset moved before manual");
assert(matcher.explain(json(fs.readfile(directory+"/sing-box.json")),{source_ip:"2001:db8::5",domain:"cdn.epic.example",inbound:"tproxy-in",protocol:"tls",network:"tcp",port:443,destination_ip:"203.0.113.20"},{},{}).outbound==epic.owner+"_store-out","removing Steam preserves Epic routing");
fs.writefile(prepared.path,"changed");
assert(!hooks.validate(prepared.path),"tampered candidate rejected");
'
test "$(stat -c %a "$WORK_DIR/stage/trafira")" = 600
printf 'profile candidate runtime checks passed\n'
