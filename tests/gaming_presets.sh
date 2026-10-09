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
print("gaming preset builder checks passed\n");
'
