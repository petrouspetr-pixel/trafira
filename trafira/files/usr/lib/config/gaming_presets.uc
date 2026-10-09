let ip=require("core.ip"),alice=require("config.alice"),common=require("core.common");
function clone(value){return json(sprintf("%J",value));}
function fail(error){return {valid:false,errors:[error],conflicts:[error]};}
function list(value){return type(value)=="array"?value:[];}
function fingerprint(section){
    let clean={};
    for(let key in sort(keys(section)))
        if(substr(key,0,1)!="." && substr(key,0,7)!="preset_")clean[key]=section[key];
    // An exact canonical fingerprint avoids hash collisions and needs no crypto package.
    return sprintf("%J",clean);
}
function host(value){
    if(type(value)!="string")return null;
    let parts=split(value,"/"),address=parts[0],family=ip.ip_family(address);
    if(!family || length(parts)>2 || (length(parts)==2 && parts[1]!=(family==4?"32":"128")))return null;
    for(let range in ["0.0.0.0/8","127.0.0.0/8","224.0.0.0/3","::/128","::1/128","ff00::/8","fe80::/10","::ffff:0:0/96"])
        if(ip.ip_in_cidr(address,range))return null;
    return {address,cidr:address+(family==4?"/32":"/128")};
}
function same(a,b){return ip.ip_in_cidr(split(a,"/")[0],b) && ip.ip_in_cidr(split(b,"/")[0],a);}
function identity(device){return lc(device.mac||"")+"@"+(device.interface||"");}
function owner_id(preset,device){
    let value=identity(device),encoded="";
    for(let n=0;n<length(value);n++)encoded+=sprintf("%02x",ord(value,n));
    return "game_"+preset.id+"_"+encoded;
}
function remove(owner,mode,confirm,current){
    if(type(owner)!="string" || !match(owner,/^game_[a-z0-9_]{1,110}$/) || index(["delete","keep"],mode)<0)return fail("invalid_owner");
    let config=[],found=false;
    for(let section in current.sections) {
        if(section.preset_owner!=owner){push(config,clone(section));continue;}
        found=true;
        if(mode=="delete") {
            if(fingerprint(section)!=section.preset_original_digest && confirm!==true)return fail("preset_edited");
        } else {
            let ordinary=clone(section);
            for(let key in keys(ordinary))if(substr(key,0,7)=="preset_")delete ordinary[key];
            push(config,ordinary);
        }
    }
    return found?{valid:true,errors:[],conflicts:[],config,owner,patch:{sections:[]}}:fail("preset_not_found");
}
function build(preset,request,current){
    if(type(preset)!="object" || !match(preset.id||"",/^(steam|playstation|xbox|epic)$/) || !length(list(preset.domains)))return fail("invalid_preset");
    if(request.expected_digest!=current.digest || !current.digest)return fail("conflict");
    if(index(["before-device-routes","after-device-routes"],request.placement)<0)return fail("placement_required");
    if(!length(list(request.device_ips)) || length(request.device_ips)>16)return fail("device_required");
    let addresses=[],device=null;
    for(let value in request.device_ips) {
        let address=host(value);if(!address)return fail("invalid_device_address");
        if(length(filter(addresses,(entry)=>same(entry,address.cidr))))continue;
        let matches=filter(list(current.devices),(entry)=>length(filter(list(entry.ips),(known)=>host(known) && same(host(known).cidr,address.cidr))));
        if(!length(matches))return fail("unknown_device");
        let first=matches[0];
        if(!ip.valid_mac(first.mac) || !alice.valid_interface_name(first.interface) || index(first.interface,"*")>=0)return fail("unknown_device_identity");
        if(length(filter(matches,(entry)=>identity(entry)!=identity(first))))return fail("ambiguous_device");
        if(device && identity(first)!=identity(device))return fail("different_devices");
        device=first;push(addresses,address.cidr);
    }
    sort(addresses);
    let config=clone(current.sections),settings=filter(config,(s)=>s[".type"]=="settings")[0];
    let proxy=filter(config,(s)=>s[".name"]==request.proxy_section && s[".type"]=="section")[0];
    if(!settings || !proxy || !common.bool_option(proxy,"enabled",true) || index(["connection","proxy","vpn","outbound"],proxy.action)<0 || proxy.preset_owner)return fail("invalid_proxy");
    let ac=alice.config(settings),conflicts=[];
    if(ac.enabled)for(let address in addresses) {
        let matched=alice.match_device(ac,{...device,ips:[split(address,"/")[0]]});
        if(alice.routes_through_trafira(ac,matched))continue;
        if(request.enable_device!==true)return fail("alice_bypass");
        if(ac.list_mode=="allow")push(ac.ips,address);
        else {
            if(substr(matched||"",0,3)!="ip:")return fail("alice_broad_bypass");
            for(let entry in ac.ips)
                if(ip.ip_in_cidr(split(address,"/")[0],entry) && (!host(entry) || !same(host(entry).cidr,address)))return fail("alice_broad_bypass");
            ac.ips=filter(ac.ips,(entry)=>!host(entry) || !same(host(entry).cidr,address));
        }
        settings.alice_ips=ac.ips;push(conflicts,"alice_device_enabled");
    }
    let owner=owner_id(preset,device);
    if(length(owner)>110)return fail("device_identity_too_long");
    let old=filter(config,(s)=>s.preset_owner==owner);
    if(length(filter(old,(s)=>fingerprint(s)!=s.preset_original_digest)) && request.replace_edited!==true)return fail("preset_edited");
    config=filter(config,(s)=>s.preset_owner!=owner);
    let store={".name":owner+"_store",".type":"section",enabled:"1",label:preset.id+" store / "+join(", ",addresses),action:"connection",outbound_jsons:[sprintf("%J",{type:"selector",tag:owner+"_target",outbounds:[request.proxy_section+"-out"]})],outbound_detour_enabled:"1",outbound_detour_section:request.proxy_section,source_ip_cidr:addresses,domain:[],domain_suffix:[]};
    for(let entry in preset.domains) {
        if(!match(entry.value||"",/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/) || index(["exact","suffix"],entry.match)<0)return fail("invalid_catalog_domain");
        push(entry.match=="exact"?store.domain:store.domain_suffix,entry.value);
    }
    let direct={".name":owner+"_direct",".type":"section",enabled:"1",label:preset.id+" other traffic / "+join(", ",addresses),action:"bypass",fully_routed_ips:addresses};
    let additions=[store,direct];
    for(let section in additions) {
        if(length(filter(config,(s)=>s[".name"]==section[".name"])))return fail("section_name_collision");
        section.preset_owner=owner;section.preset_revision=""+preset.revision;section.preset_platform=preset.id;
        section.preset_original_digest=fingerprint(section);
    }
    for(let section in config)if(section[".type"]=="section" && common.bool_option(section,"enabled",true) && (length(list(section.fully_routed_ips)) || length(list(section.source_ip_cidr))))push(conflicts,"existing_device_routes:"+section[".name"]);
    let output=[],inserted=false;
    for(let section in config) {
        if(!inserted && request.placement=="before-device-routes" && section[".type"]=="section") {push(output,...additions);inserted=true;}
        push(output,section);
    }
    if(!inserted)push(output,...additions);
    return {valid:true,errors:[],owner,config:output,patch:{sections:additions},conflicts,limitations:preset.limitations||[]};
}
return {build,remove,fingerprint,host};
