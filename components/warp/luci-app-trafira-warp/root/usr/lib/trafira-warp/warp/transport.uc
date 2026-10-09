// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),job=require("warp.job");
function valid_interface(value){return type(value)=="string" && match(value,/^tfwarp[0-9]$/);}
function ipv4(value) {
    if(type(value)!="string" || !match(value,/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/))return false;
    for(let part in split(value,"."))if(length(part)>3 || int(part)>255 || (length(part)>1 && substr(part,0,1)=="0"))return false;
    return true;
}
function ipv6(value) {
    if(type(value)!="string" || !match(value,/^[a-fA-F0-9:]+$/))return false;
    let doubles=split(value,"::"),groups=filter(split(value,":"),(part)=>length(part)>0);
    if(length(doubles)>2 || (length(doubles)==1?length(groups)!=8:length(groups)>=8))return false;
    for(let part in groups)if(length(part)>4)return false;
    return true;
}
function valid_endpoint(value) {
    if(type(value)!="string")return false;
    let parts=split(value,":");
    if(length(parts)!=2 || !ipv4(parts[0]) || !match(parts[1],/^[1-9][0-9]{0,4}$/) || int(parts[1])>65535)return false;
    let octets=map(split(parts[0],"."),(part)=>int(part));
    return (octets[0]==162 && octets[1]==159) || (octets[0]==188 && octets[1]==114) || (octets[0]==8 && octets[1]==47);
}
function choose_interface(sections,devices) {
    for(let n=0;n<10;n++){let name="tfwarp"+n;if(!sections[name] && index(devices,name)<0)return name;}
    return null;
}
function valid_config(c) {
    if(type(c)!="object" || !valid_interface(c.interface) || !valid_endpoint(c.endpoint) || c.fwmark!=134217728 || c.mtu!=1280 || !ipv4(c.ipv4) || (c.ipv6 && !ipv6(c.ipv6)))return false;
    for(let key in ["private_key","peer_public_key"])if(type(c[key])!="string" || !match(c[key],/^[A-Za-z0-9+\/]{43}=$/))return false;
    if(type(c.jc)!="int" || c.jc<1 || c.jc>10 || type(c.jmin)!="int" || type(c.jmax)!="int" || c.jmin<1 || c.jmax<c.jmin || c.jmax>1280)return false;
    return (type(c.i1)=="string" && length(c.i1)>0 && length(c.i1)<=8192 && !match(c.i1,/[\r\n]/));
}
function network_section(name){return {proto:"none",device:name,auto:"0",defaultroute:"0",peerdns:"0",delegate:"0",trafira_warp_managed:"1"};}
function address_commands(c,enable_ipv6) {
    let commands=[["ip","address","replace",c.ipv4+"/32","dev",c.interface]];
    if(enable_ipv6 && c.ipv6)push(commands,["ip","-6","address","replace",c.ipv6+"/128","dev",c.interface]);
    return commands;
}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function output(args) {
    let p=fs.popen("exec "+join(" ",map(args,quote))+" 2>/dev/null","re");if(!p)return null;
    let value=p.read(65537),code=p.close();return code==0 && length(value||"")<=65536?trim(value):null;
}
function status() {
    let c=state.load(state.DIRECTORY+"/transport.json"),runtime=state.load(state.RUNTIME+"/transport.json");
    let inactive={schema:1,owner:"trafira-warp",success:true,running:false,enabled:c?.enabled===true,generation:c?.generation||0};
    if(!c || !valid_config(c) || !runtime || runtime.ready!==true || runtime.generation!=c.generation || !job.live(runtime.worker))return inactive;
    if(fs.readlink("/proc/"+runtime.worker.pid+"/exe")!="/usr/libexec/trafira-warp-amneziawg-go")return {...inactive,error:"ownership_error"};
    let cursor=require("uci").cursor(),section=cursor.get_all("network",c.interface);
    if(!section || section.trafira_warp_managed!="1" || section.device!=c.interface || section.proto!="none")return {...inactive,error:"ownership_error"};
    if(trim(fs.readfile("/sys/class/net/"+c.interface+"/ifindex")||"")!=runtime.ifindex)return {...inactive,error:"ownership_error"};
    let socket=fs.lstat("/var/run/amneziawg/"+c.interface+".sock");
    if(!socket || socket.type!="socket" || !fs.stat("/sys/class/net/"+c.interface))return inactive;
    let ctl="/usr/libexec/trafira-warp-awgctl",mark=output([ctl,"get",c.interface,"fwmark"]),endpoint=output([ctl,"get",c.interface,"endpoint"]),port=output([ctl,"get",c.interface,"listen_port"]);
    if(int(mark)!=c.fwmark || !valid_endpoint(endpoint) || !match(port||"",/^[0-9]+$/) || int(port)<1 || int(port)>65535)return {...inactive,error:"transport_mismatch"};
    let handshake=output([ctl,"get",c.interface,"last_handshake_time_sec"]),age=handshake && int(handshake)>0?clock()[0]-int(handshake):null;
    return {...inactive,running:true,interface:c.interface,endpoint,listen_port:int(port),fwmark:c.fwmark,handshake_age:age,https_ok:runtime.https_ok===true,warp:runtime.warp===true};
}
function owned(section,name) {
    if(!section)return false;
    let expected=network_section(name);
    for(let key in expected)if(section[key]!=expected[key])return false;
    return section[".type"]=="interface";
}
function config_text(c) {
    return "[Interface]\nPrivateKey = "+c.private_key+"\nFwMark = "+c.fwmark+"\nJc = "+c.jc+"\nJmin = "+c.jmin+"\nJmax = "+c.jmax+"\nI1 = "+c.i1+
        "\n\n[Peer]\nPublicKey = "+c.peer_public_key+"\nEndpoint = "+c.endpoint+"\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n";
}
function routing_identity(name) {
    if(!valid_interface(name))return null;
    let number=int(substr(name,6));return {priority:18090+number,table:51890+number};
}
function route_setup(c) {
    let owned_route=routing_identity(c.interface);
    for(let family in ["-4","-6"]) {
        if(family=="-6" && (!c.ipv6 || trim(fs.readfile("/proc/sys/net/ipv6/conf/all/disable_ipv6")||"1")=="1"))continue;
        let text=output(["ip",family,"-j","rule","show"]),routes=output(["ip",family,"-j","route","show","table","all"]);
        let rules,entries;
        try {rules=json(text);entries=json(routes);}catch(e){return false;}
        if(type(rules)!="array" || type(entries)!="array")return false;
        entries=filter(entries,(route)=>int(route.table)==owned_route.table);
        let found=false;
        for(let rule in rules) {
            if(rule.priority!=owned_route.priority && rule.table!=owned_route.table)continue;
            if(rule.priority!=owned_route.priority || rule.table!=owned_route.table || rule.oif!=c.interface)return false;
            found=true;
        }
        for(let route in entries)if(route.dst!="default" || route.dev!=c.interface || route.gateway)return false;
        if(!length(entries) && output(["ip",family,"route","add","default","dev",c.interface,"table",""+owned_route.table])==null)return false;
        if(!found && output(["ip",family,"rule","add","priority",""+owned_route.priority,"oif",c.interface,"lookup",""+owned_route.table])==null)return false;
    }
    return true;
}
function route_clear(c) {
    let owned_route=routing_identity(c.interface);if(!owned_route)return false;
    for(let family in ["-4","-6"]) {
        let text=output(["ip",family,"-j","rule","show"]),routes=output(["ip",family,"-j","route","show","table","all"]),rules,entries;
        try {rules=json(text);entries=json(routes);}catch(e){return false;}
        if(type(rules)!="array" || type(entries)!="array")return false;
        for(let rule in rules)if(rule.priority==owned_route.priority || int(rule.table)==owned_route.table) {
            if(rule.priority!=owned_route.priority || int(rule.table)!=owned_route.table || rule.oif!=c.interface)return false;
            if(output(["ip",family,"rule","del","priority",""+owned_route.priority,"oif",c.interface,"lookup",""+owned_route.table])==null)return false;
        }
        for(let route in entries)if(int(route.table)==owned_route.table) {
            if(route.dst!="default" || route.dev!=c.interface || route.gateway)return false;
            if(output(["ip",family,"route","del","default","dev",c.interface,"table",""+owned_route.table])==null)return false;
        }
    }
    return true;
}
function snapshot() {
    let config=state.load(state.DIRECTORY+"/transport.json"),cursor=require("uci").cursor();
    return {config,network:config?cursor.get_all("network",config.interface):null,running:status().running};
}
function mark_available(mark) {
    for(let family in ["-4","-6"]) {
        let rules=output(["ip",family,"rule","show"]);if(rules==null)return false;
        for(let line in split(rules,"\n")) {
            let found=match(line,/fwmark (0x[0-9a-fA-F]+|[0-9]+)(?:\/(0x[0-9a-fA-F]+|[0-9]+))?/);
            if(found && (mark & (found[2]?int(found[2]):4294967295))==(int(found[1]) & (found[2]?int(found[2]):4294967295)))return false;
        }
    }
    return true;
}
function apply(config,id) {
    let c={...config},cursor=require("uci").cursor(),old=state.load(state.DIRECTORY+"/transport.json");
    if(!valid_config(c) || !mark_available(c.fwmark))return {success:false,error:"invalid_transport"};
    let existing=cursor.get_all("network",c.interface);
    if(existing && (!old || old.interface!=c.interface || !owned(existing,c.interface)))return {success:false,error:"interface_conflict"};
    if(!existing && fs.stat("/sys/class/net/"+c.interface))return {success:false,error:"interface_conflict"};
    let was_running=status().running;
    if(output(["/etc/init.d/trafira-warp","stop"])==null && was_running)return {success:false,error:"stop_failed"};
    c.generation=(old?.generation||0)+1;
    if(!state.save_text(state.DIRECTORY+"/awg.conf",config_text(c)) || !state.save(state.DIRECTORY+"/transport.json",c))return {success:false,error:"storage_unavailable"};
    if(!existing) {
        cursor.set("network",c.interface,"interface");
        for(let key,value in network_section(c.interface))cursor.set("network",c.interface,key,value);
        if(!cursor.commit("network"))return {success:false,error:"network_commit_failed"};
        let dynamic={name:c.interface,...network_section(c.interface)};
        if(output(["ubus","call","network","add_dynamic",sprintf("%J",dynamic)])==null)return {success:false,error:"network_apply_failed"};
    }
    if(c.enabled!==true)return {success:true,enabled:false};
    if(output(["/etc/init.d/trafira-warp","start"])==null)return {success:false,error:"start_failed"};
    for(let n=0;n<10;n++) {
        if(job.cancelled(id))return {success:false,error:"cancelled"};
        if(status().running)return {success:true,enabled:true};
        system("sleep 1");
    }
    return {success:false,error:"start_failed"};
}
function restore(saved,id) {
    let current=state.load(state.DIRECTORY+"/transport.json"),cursor=require("uci").cursor();
    if(saved.config) {
        let result=apply({...saved.config,enabled:saved.running===true},id);
        if(!result.success)return false;
        // Preserve desired boot state independently of current service activity.
        let restored=state.load(state.DIRECTORY+"/transport.json");
        return restored && state.save(state.DIRECTORY+"/transport.json",{...restored,enabled:saved.config.enabled===true});
    }
    if(current) {
        let existing=cursor.get_all("network",current.interface);
        if(existing && !owned(existing,current.interface))return false;
        output(["/etc/init.d/trafira-warp","stop"]);
        if(!route_clear(current))return false;
        if(existing) {
            output(["ubus","call","network.interface."+current.interface,"down"]);
            cursor.delete("network",current.interface);if(!cursor.commit("network"))return false;
        }
    }
    return state.remove(state.DIRECTORY+"/transport.json") && state.remove(state.DIRECTORY+"/awg.conf");
}
return {routing_identity,route_setup,route_clear,owned,config_text,snapshot,apply,restore,mark_available,valid_interface,ipv4,ipv6,valid_endpoint,choose_interface,valid_config,network_section,address_commands,status,quote,output};
