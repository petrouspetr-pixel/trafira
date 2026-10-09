// A failed or interrupted transition keeps its kernel guard. It is released
// only after a verified configuration, or an explicit Trafira stop/restart.
let fs=require("fs"),store=require("singbox.failure_store"),transform=require("singbox.failure_config");
let locks=require("service.operation_lock"),uci=require("core.uci"),constants=require("core.constants"),provenance=require("singbox.provenance");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function command(args){return join(" ",map(args,quote));}
function run(args,timeout){return system("exec "+command(args)+" </dev/null >/dev/null 2>&1",timeout||60000)==0;}
function state_command(args){return ["ucode","-L",LIB,LIB+"/service/state.uc",...args];}
function config_path(){return uci.get("trafira.settings.config_path")||"/etc/sing-box/config.json";}
function transition(expected,hooks) {
    let guarded=false,stage="prepare";
    try {
        if(hooks.generation()!=expected)return {success:false,error:"conflict"};
        if(!hooks.prepare())return {success:false,error:"candidate_check_failed"};
        if(hooks.generation()!=expected)return {success:false,error:"conflict"};
        stage="guard";
        if(!hooks.guard())return {success:false,error:"guard_failed"};
        guarded=true;
        for(let next in ["install","reload","healthy","publish","unguard"]) {
            stage=next;
            if(!hooks[next]()) {
                let restored=hooks.restore();
                return {success:false,error:next+"_failed",guarded:true,restored};
            }
        }
        return {success:true,guarded:false};
    }catch(e) {
        let restored=false;
        if(guarded)try {restored=hooks.restore();}catch(ignored){}
        return {success:false,error:stage+"_failed",guarded,restored};
    }
}
function guard_script(ports,mark) {
    mark=mark||"0x04000000";
    if(!match(mark,/^0x[0-9a-fA-F]{1,8}$/))return null;
    let safe=[];
    for(let port in ports||[]) {
        if(type(port)!="int" || port<1 || port>65535)return null;
        if(index(safe,port)<0)push(safe,port);
    }
    let text="add table inet TrafiraFailureGuard\nflush table inet TrafiraFailureGuard\n"+
        "add chain inet TrafiraFailureGuard capture { type filter hook prerouting priority -149; policy accept; }\n"+
        "add rule inet TrafiraFailureGuard capture meta mark & "+mark+" != 0 counter drop\n"+
        "add chain inet TrafiraFailureGuard local { type filter hook input priority -151; policy accept; }\n";
    if(length(safe))text+="add rule inet TrafiraFailureGuard local meta l4proto { tcp, udp } th dport { "+join(", ",safe)+" } counter drop\n";
    // The legacy DNS listener receives forwarded dnsmasq requests on loopback.
    text+="add rule inet TrafiraFailureGuard local ip daddr 127.0.0.42 meta l4proto { tcp, udp } th dport 53 counter drop\n";
    return text;
}
function clear_guard() {
    if(!run(["nft","list","table","inet","TrafiraFailureGuard"]))return true;
    return run(["nft","delete","table","inet","TrafiraFailureGuard"]);
}
function guarded_ports(base) {
    let names={},ports=[1602,1603,1604],outbounds={};
    for(let section in base.sections)outbounds[require("singbox.constants").outbound_tag(section[".name"])]=true;
    for(let rule in base.config.route.rules||[]) {
        if(!outbounds[rule.outbound])continue;
        let inbound=type(rule.inbound)=="array"?rule.inbound:[rule.inbound];
        for(let name in inbound)if(type(name)=="string" && substr(name,0,8)!="service-")names[name]=true;
    }
    for(let inbound in base.config.inbounds||[])
        if(names[inbound.tag] && type(inbound.listen_port)=="int" && index(ports,inbound.listen_port)<0)push(ports,inbound.listen_port);
    return ports;
}
function apply_states(expected,states) {
    let lock=locks.acquire("failure-policy",false);
    if(!lock)return {success:false,error:"busy"};
    let path=config_path(),base=store.load(path),result,directory="";
    try {
        if(!base || base.generation!=expected)result={success:false,error:"conflict"};
        else {
            directory=ROOT+sprintf("/failure-apply-%x-%x",clock()[0],clock()[1]);
            if(!fs.mkdir(directory,448))result={success:false,error:"storage_unavailable"};
            else {
                let previous=store.read(path),candidate=transform.apply(base.config,base.sections,states);
                let origins=provenance.extract(candidate),candidate_path=directory+"/candidate.json",guard_path=directory+"/guard.nft";
                require("core.common").strip_internal_fields(candidate);
                let script=guard_script(guarded_ports(base),constants.NFT_FAKEIP_MARK);
                let file=fs.open(guard_path,"wex",384),saved=false;
                if(file) {saved=file.write(script||"")==length(script||"");file.close();}
                let current=()=>{let value=store.load(path);return value?value.generation+":"+value.applied_digest:"";};
                let pid_stream=fs.popen(command(state_command(["sing-box-service-runtime-pid"]))+" 2>/dev/null","re");
                let previous_pid=pid_stream?trim(pid_stream.read(64)||""):"";if(pid_stream)pid_stream.close();
                let reload=()=>run(state_command(["reload-sing-box-runtime",previous_pid,"before","after","1"]),30000);
                let healthy=()=>run(state_command(["wait-trafira-stable-start",constants.RT_TABLE_NAME,constants.NFT_TABLE_NAME,constants.NFT_FAKEIP_MARK,"2","20"]),30000);
                result=transition(base.generation+":"+base.applied_digest,{
                    generation:current,
                    prepare:()=>previous && script && saved && store.write(candidate_path,candidate) && run(["sing-box","-c",candidate_path,"check"],15000),
                    guard:()=>run(["nft","-f",guard_path]),
                    install:()=>store.write(path,candidate),reload,healthy,
                    publish:()=>provenance.save(path,origins) && store.publish(base.generation,path,states),
                    unguard:clear_guard,
                    restore:()=>store.write(path,previous) && store.publish(base.generation,path,base.states) && reload() && healthy()
                });
                if(result.success)result.applied_generation=base.generation;
                store.write(ROOT+"/failure-policy-result.json",{...result,generation:base.generation,changed_at:int(clock(true)[0])});
            }
        }
    }catch(e){result={success:false,error:"apply_failed",guarded:run(["nft","list","table","inet","TrafiraFailureGuard"])};}
    if(directory)run(["rm","-rf",directory]);
    locks.release(lock);return result;
}
function apply(section,expected,target) {
    let base=store.load(config_path());
    if(!base || base.generation!=expected)return {success:false,error:"conflict"};
    let found=null;for(let item in base.sections)if(item[".name"]==section)found=item;
    if(!found || index(["primary","reserve","direct","blocked"],target)<0 ||
        (target=="direct" && found.failure_policy!="direct") || (target=="reserve" && found.failure_policy!="reserve"))return {success:false,error:"invalid_target"};
    let states={...base.states};states[section]={...(states[section]||{}),mode:target};
    return apply_states(expected,states);
}
return {transition,guard_script,clear_guard,apply,apply_states,config_path};
