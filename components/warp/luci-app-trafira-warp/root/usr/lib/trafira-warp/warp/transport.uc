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
    if(type(c.jc)!="int" || c.jc<0 || c.jc>10 || type(c.jmin)!="int" || type(c.jmax)!="int" || c.jmin<0 || c.jmax<c.jmin || c.jmax>1280)return false;
    return c.i1==null || (type(c.i1)=="string" && length(c.i1)<=8192 && !match(c.i1,/[\r\n]/));
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
    if(!c || !valid_config(c) || !runtime || !job.live(runtime.worker))return inactive;
    if(fs.readlink("/proc/"+runtime.worker.pid+"/exe")!="/usr/libexec/trafira-warp-amneziawg-go")return {...inactive,error:"ownership_error"};
    let cursor=require("uci").cursor(),section=cursor.get_all("network",c.interface);
    if(!section || section.trafira_warp_managed!="1" || section.device!=c.interface || section.proto!="none")return {...inactive,error:"ownership_error"};
    let socket=fs.lstat("/var/run/amneziawg/"+c.interface+".sock");
    if(!socket || socket.type!="socket" || !fs.stat("/sys/class/net/"+c.interface))return inactive;
    let ctl="/usr/libexec/trafira-warp-awgctl",mark=output([ctl,"get",c.interface,"fwmark"]),endpoint=output([ctl,"get",c.interface,"endpoint"]),port=output([ctl,"get",c.interface,"listen_port"]);
    if(int(mark)!=c.fwmark || !valid_endpoint(endpoint) || !match(port||"",/^[0-9]+$/) || int(port)<1 || int(port)>65535)return {...inactive,error:"transport_mismatch"};
    let handshake=output([ctl,"get",c.interface,"last_handshake_time_sec"]),age=handshake && int(handshake)>0?clock()[0]-int(handshake):null;
    return {...inactive,running:true,interface:c.interface,endpoint,listen_port:int(port),fwmark:c.fwmark,handshake_age:age,https_ok:runtime.https_ok===true,warp:runtime.warp===true};
}
return {valid_interface,ipv4,ipv6,valid_endpoint,choose_interface,valid_config,network_section,address_commands,status,quote,output};
