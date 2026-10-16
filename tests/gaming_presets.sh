#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let g=require("config.gaming_presets");
let preset={id:"steam",revision:1,domains:[{value:"store.example",match:"exact",purpose:"store"}],limitations:[]};
let settings={".name":"settings",".type":"settings"},vpn={".name":"vpn",".type":"section",enabled:"1",action:"connection"};
let device={interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]};
let current={sections:[settings,vpn],devices:[device],digest:"test"};
let request={device_ips:["192.0.2.5/32","2001:db8::5/128"],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"};
let result=g.build(preset,request,current);
assert(result.valid,sprintf("%J",result));
assert(length(result.patch.sections)==2,"two editable routes");
assert(length(result.patch.sections[0].source_ip_cidr)==2 && result.patch.sections[0].domain[0]=="store.example","device AND destination");
assert(result.patch.sections[1].action=="bypass" && length(result.patch.sections[1].fully_routed_ips)==2,"only selected device remainder direct");
assert(result.patch.sections[0].outbound_detour_section=="vpn","store uses selected connection");
assert(!g.build(preset,{...request,device_ips:[]},current).valid,"no wildcard device");
for(let address in ["0.0.0.0/0","::/0","192.0.2.0/24","224.0.0.1/32","::/128","192.0.2.6/32"])
 assert(!g.build(preset,{...request,device_ips:[address]},current).valid,"invalid or unknown host: "+address);
assert(!g.build(preset,{...request,expected_digest:"old"},current).valid,"stale preview rejected");
assert(!g.build(preset,request,{...current,sections:[settings,{...vpn,enabled:"0"}]}).valid,"disabled proxy rejected");
let again=g.build(preset,request,{...current,sections:result.config});
assert(again.valid && length(again.config)==length(result.config),"idempotent apply");
let saved=json(sprintf("%J",result.config));
// UCI does not persist empty lists: exercise that serialized representation.
for(let section in saved)for(let key in keys(section))if(type(section[key])=="array" && !length(section[key]))delete section[key];
assert(g.build(preset,request,{...current,sections:saved}).valid,"unmodified persisted preset is idempotent");
assert(g.remove(result.owner,"delete",false,{...current,sections:saved}).valid,"unmodified persisted preset deletes without edited confirmation");
let edited=json(sprintf("%J",result.config));
for(let section in edited)if(section.preset_owner) {section.label="User edit";break;}
assert(!g.build(preset,request,{...current,sections:edited}).valid,"user edits need explicit replacement");
assert(g.build(preset,{...request,replace_edited:true},{...current,sections:edited}).valid,"reviewed replacement allowed");
let bypass={...settings,alice_mode_enabled:"1",alice_list_mode:"allow",alice_ips:[]};
assert(!g.build(preset,request,{...current,sections:[bypass,vpn]}).valid,"Alice bypass must not silently enable device");
let enabled=g.build(preset,{...request,enable_device:true},{...current,sections:[bypass,vpn]});
assert(enabled.valid && length(enabled.config[0].alice_ips)==2,"explicit Alice change restricted to host addresses");
let broad={...settings,alice_mode_enabled:"1",alice_list_mode:"deny",alice_ips:["192.0.2.0/24"]};
assert(!g.build(preset,{...request,enable_device:true},{...current,sections:[broad,vpn]}).valid,"broad bypass cannot be removed for other devices");
let removed=g.remove(result.owner,"delete",false,{...current,sections:result.config});
assert(removed.valid && length(removed.config)==2 && removed.config[1][".name"]=="vpn","removal keeps unowned sections");
let kept=g.remove(result.owner,"keep",false,{...current,sections:edited});
assert(kept.valid && !filter(kept.config,(s)=>s.preset_owner)[0],"edited rules can become ordinary rules");
let paused=g.set_enabled(false,{...current,sections:result.config});
assert(paused.valid && paused.config[0].gaming_presets_enabled=="0","persist global switch");
assert(!length(filter(paused.config,(s)=>s.preset_owner && s.enabled!="0")),"disable both preset routes");
assert(paused.config[3][".name"]=="vpn" && paused.config[3].enabled=="1","ordinary connection remains active");
assert(!g.build(preset,request,{...current,sections:paused.config}).valid,"cannot create active rules while globally paused");
let staged=g.build(preset,{...request,enable_gaming:true},{...current,sections:paused.config});
assert(staged.valid && staged.config[0].gaming_presets_enabled=="1","pending switch enables candidate and preset in one transaction");
assert(length(filter(staged.config,(s)=>s.preset_owner && s.enabled=="1"))==2,"candidate routes are active");
assert(paused.config[0].gaming_presets_enabled=="0" && !length(filter(paused.config,(s)=>s.preset_owner && s.enabled!="0")),"preview never mutates saved switch or routes");
assert(!g.build(preset,{...request,enable_gaming:"1"},{...current,sections:paused.config}).valid,"explicit enable must be boolean");
assert(!g.build(preset,{...request,enable_gaming:true,expected_digest:"old"},{...current,sections:paused.config}).valid,"pending enable preserves digest conflict check");
let resumed=g.set_enabled(true,{...current,sections:g.set_enabled(false,{...current,sections:paused.config}).config});
assert(length(filter(resumed.config,(s)=>s.preset_owner && s.enabled=="1"))==2,"repeat disable preserves restoration");
assert(g.remove(result.owner,"delete",false,{...current,sections:resumed.config}).valid,"toggle does not mark unedited rules edited");
let manually_disabled=json(sprintf("%J",result.config));
for(let section in manually_disabled)if(section.preset_owner) {section.enabled="0";section.label="User edit";break;}
let restored=g.set_enabled(true,{...current,sections:g.set_enabled(false,{...current,sections:manually_disabled}).config});
assert(length(filter(restored.config,(s)=>s.preset_owner && s.enabled=="0"))==1,"do not reactivate individually disabled rules");
assert(!g.remove(result.owner,"delete",false,{...current,sections:restored.config}).valid,"edited warning survives toggle");
assert(!g.set_enabled("0",current).valid,"reject non boolean enable request");
// Regression: every store wins before any same-device direct fallback.
let epic={...preset,id:"epic",domains:[{value:"epic.example",match:"suffix"}]};
let manual={".name":"manual",".type":"section",enabled:"1",action:"bypass",fully_routed_ips:["192.0.2.5/32"]};
let first=g.build(preset,request,{...current,sections:[settings,manual,vpn]});
let both=g.build(epic,{...request,placement:"after-device-routes"},{...current,sections:first.config});
assert(both.valid,"second platform");
let owned=filter(both.config,(s)=>s.preset_owner);
assert(owned[0].action=="connection" && owned[1].action=="connection" && owned[2].action=="bypass","all stores before direct");
assert(both.config[1][".name"]=="manual" && both.config[2][".name"]=="vpn","latest priority moves complete group after manual");
let before=g.build(preset,request,{...current,sections:both.config});
assert(before.config[1].preset_owner && before.config[4].preset_owner && before.config[5][".name"]=="manual","whole group moves before manual");
let legacy=[settings,first.patch.sections[0],first.patch.sections[1],manual,...both.patch.sections,vpn];
let normalized=g.normalize(legacy);
assert(normalized[1].action=="connection" && normalized[2].action=="connection" && normalized[5][".name"]=="manual","legacy grouping at earliest position");
assert(sprintf("%J",legacy[3])==sprintf("%J",normalized[5]),"manual content unchanged");
let without=g.remove(first.owner,"delete",false,{...current,sections:both.config});
assert(without.valid && length(filter(without.config,(s)=>s.preset_owner))==2,"remove Steam preserves Epic");
let draft_request={...request};delete draft_request.expected_digest;
let second_device={...device,mac:"02:00:00:00:00:02",ips:["192.0.2.6"]};
let independent=g.build(preset,{...request,device_ips:["192.0.2.6/32"],placement:"before-device-routes"},{...current,devices:[device,second_device],sections:both.config});
assert(independent.valid && length(filter(independent.config,(s)=>s.preset_owner))==6,"different device identity independent");
let other_group=filter(independent.config,(s)=>s.preset_owner==independent.owner);
let moved=g.build(epic,request,{...current,devices:[device,second_device],sections:independent.config});
assert(moved.valid && sprintf("%J",filter(moved.config,(s)=>s.preset_owner==independent.owner))==sprintf("%J",other_group),"moving first device preserves other group content and order");
let disabled_group=json(sprintf("%J",both.config));
for(let section in disabled_group)if(section.preset_owner==first.owner && section.action=="connection")section.enabled="0";
let updated=g.build(epic,request,{...current,sections:disabled_group});
let unchanged_steam=filter(updated.config,(s)=>s.preset_owner==first.owner && s.action=="connection")[0];
assert(updated.valid && unchanged_steam.enabled=="0" && unchanged_steam.preset_original_digest==first.patch.sections[0].preset_original_digest,"group move preserves disabled state and edited fingerprint");
assert(length(unchanged_steam.source_ip_cidr)==2,"group move preserves IPv6 selection");
let plan=g.plan({sections:[settings,vpn],operations:[{action:"upsert",preset:"steam",...draft_request},{action:"upsert",preset:"epic",...draft_request}]},[preset,epic],[device]);
assert(plan.success && length(plan.owners)==2,"batch adds both platforms");
let retry=g.plan({sections:plan.config,operations:[{action:"remove",owner:first.owner,mode:"delete"},{action:"remove",owner:first.owner,mode:"delete"}]},[preset,epic],[device]);
assert(retry.success && length(retry.owners)==1,"Save retry removal is idempotent");
let original=sprintf("%J",plan.config);
assert(!g.plan({sections:plan.config,operations:[{action:"remove",owner:first.owner,mode:"delete"},{action:"upsert",preset:"missing",...draft_request}]},[preset,epic],[device]).success,"batch fails atomically");
assert(sprintf("%J",plan.config)==original,"failed batch never mutates supplied draft");
let off=g.plan({sections:[{...settings,gaming_presets_enabled:"0"},vpn],operations:[{action:"upsert",preset:"steam",...draft_request}]},[preset],[device]);
assert(off.success && off.config[0].gaming_presets_enabled=="0" && !length(filter(off.config,(s)=>s.preset_owner && s.enabled!="0")),"Save uses current global disabled switch");
assert(g.plan({sections:off.config,operations:[]},[preset],[device]).success,"empty plan");
assert(!g.plan({sections:[settings,settings],operations:[]},[preset],[device]).success,"validate draft schema");
print("gaming preset builder checks passed\n");
'
