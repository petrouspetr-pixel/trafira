// SPDX-License-Identifier: GPL-3.0-only
let format=require("config.profile_format");
function clone(value){return json(sprintf("%J",value));}
function fail(error){return {success:false,error};}
function fingerprint(section) {
    let result={};
    let keys=section[".type"]=="section_interface"?[".name",".type","section","name","warp_owner"]:[".name",".type","action","enabled","failure_policy","warp_owner"];
    for(let key in keys)result[key]=section[key]==null?"":""+section[key];
    return sprintf("%J",result);
}
function mentions(value,iface,depth) {
    if(depth>32)return true;
    if(type(value)=="object") {
        if(value.bind_interface==iface)return true;
        for(let key,item in value)if(mentions(item,iface,depth+1))return true;
    }else if(type(value)=="array")for(let item in value)if(mentions(item,iface,depth+1))return true;
    return false;
}
function references(document,iface) {
    let found={};
    for(let section in document.config||[]) {
        let referenced=section[".type"]=="section_interface" && section.name==iface;
        for(let key in ["interfaces","interface","output_network_interface","source_network_interfaces"]) {
            let value=section[key],items=type(value)=="array"?value:[value];
            if(index(items,iface)>=0)referenced=true;
        }
        for(let key in ["outbound_json","outbound_jsons"]) {
            let values=type(section[key])=="array"?section[key]:[section[key]];
            for(let text in values)if(type(text)=="string") {
                try {if(mentions(json(text),iface,0))referenced=true;}catch(e){if(index(text,iface)>=0)referenced=true;}
            }
        }
        if(referenced)found[section[".type"]=="section_interface"?(section.section||section[".name"]):section[".name"]]=true;
    }
    return sort(keys(found));
}
function attach(document,transport,expected,actual) {
    if(!expected || expected!=actual)return fail("conflict");
    if(!format.validate(document).valid)return fail("invalid_profile");
    if(transport?.schema!=1 || transport.owner!="trafira-warp" || !match(transport.interface||"",/^tfwarp[0-9]$/) || !transport.running || !transport.https_ok || transport.warp!==true)return fail("transport_unhealthy");
    let config=clone(document.config),names={},own=[];
    for(let section in config) {names[section[".name"]]=true;if(section[".type"]=="section" && section.warp_owner=="trafira-warp")push(own,section);}
    if(length(own)>1)return fail("ownership_conflict");
    if(length(own)) {
        let parent=own[0],children=filter(config,(s)=>s[".type"]=="section_interface" && s.section==parent[".name"]);
        if(fingerprint(parent)!=parent.warp_original || length(children)!=1 || children[0].warp_owner!="trafira-warp" || fingerprint(children[0])!=children[0].warp_original || children[0].name!=transport.interface)return fail("managed_section_edited");
        return {success:true,document:clone(document),section:parent[".name"],changed:false};
    }
    let name=null;
    for(let n=0;n<100;n++){let candidate="cfwarp"+(n?""+n:"");if(!names[candidate] && !names[candidate+"_interface"]){name=candidate;break;}}
    if(!name)return fail("section_limit");
    let parent={".name":name,".type":"section",label:"WARP",action:"connection",enabled:"1",failure_policy:"block",warp_owner:"trafira-warp",community_lists:[],user_domains:[],user_subnets:[],fully_routed_ips:[]};
    let child={".name":name+"_interface",".type":"section_interface",section:name,name:transport.interface,warp_owner:"trafira-warp"};
    parent.warp_original=fingerprint(parent);child.warp_original=fingerprint(child);
    push(config,parent,child);
    return {success:true,document:{...clone(document),config},section:name,changed:true};
}
function detach(document,name,expected,actual) {
    if(!expected || expected!=actual)return fail("conflict");
    if(!format.validate(document).valid)return fail("invalid_profile");
    let own=filter(document.config,(s)=>s[".name"]==name)[0];
    if(!own || own[".type"]!="section" || own.warp_owner!="trafira-warp")return fail("not_managed");
    if(fingerprint(own)!=own.warp_original)return fail("managed_section_edited");
    let children=filter(document.config,(s)=>s.section==name);
    if(length(children)!=1 || children[0][".type"]!="section_interface" || children[0].warp_owner!="trafira-warp" || fingerprint(children[0])!=children[0].warp_original)return fail("managed_section_edited");
    let remove=[name,children[0][".name"]];
    for(let section in document.config)if(index(remove,section[".name"])<0)
        for(let key,value in section)if(match(key,/_section$/) && value==name)return fail("section_in_use");
    return {success:true,document:{...clone(document),config:filter(clone(document.config),(s)=>index(remove,s[".name"])<0)},section:name,changed:true};
}
return {attach,detach,references,fingerprint};
