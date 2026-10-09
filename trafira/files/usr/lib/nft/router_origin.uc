let fs=require("fs"),ip=require("core.ip"),common=require("core.common"),uci=require("core.uci"),model=require("config.router_origin");
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function output(args) {
    let stream=fs.popen(join(" ",map(args,quote))+" 2>/dev/null","re");if(!stream)return null;
    let text=stream.read(65537),status=stream.close();
    return status==0 && length(text||"")<=65536?text:null;
}
function resolve(name) {
    if(ip.valid_ip(name))return [name];
    if(!match(name,/^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/))return null;
    let text=output(["resolveip","-t","3",name]);if(text==null)return null;
    let result=[];for(let line in split(trim(text),"\n"))if(ip.valid_ip(trim(line)))push(result,trim(line));
    return length(result)?result:null;
}
function snapshot(settings,sections) {
    let prepared=require("singbox.failure_store").read((getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/router-bootstrap-prepared.json");
    let use_prepared=prepared && prepared.config_text==require("service.applied_config").normalized(fs.readfile(getenv("TRAFIRA_CONFIG_FILE")||"/etc/config/trafira")) && require("service.operation_lock").is_live_ancestor(prepared.worker);
    if(use_prepared)return prepared.data;

    let result={dns:[],ntp:[],vpn:[],vpn_ports:[]},known_interfaces={};
    for(let address in common.list_option(settings,"bootstrap_dns_server")) {
        if(!ip.valid_ip(address))return null;
        push(result.dns,address);
    }
    if(!length(result.dns))push(result.dns,"77.88.8.8");
    for(let path in ["/tmp/resolv.conf.d/resolv.conf.auto","/tmp/resolv.conf.auto","/etc/resolv.conf"]) {
        let stat=fs.stat(path);if(!stat || stat.size>65536)continue;
        for(let line in split(fs.readfile(path)||"","\n")) {
            let found=match(line,/^nameserver[[:space:]]+([^[:space:]]+)/);
            if(found && ip.valid_ip(found[1]))push(result.dns,found[1]);
        }
    }
    let count=0;
    for(let ntp in uci.section_objects("system","timeserver"))for(let name in common.list_option(ntp,"server")) {
        if(++count>8)return null;
        let addresses=resolve(name);if(!addresses)return null;
        for(let address in addresses)push(result.ntp,address);
    }
    for(let tool in ["awg","wg"]) {
        let ports=output([tool,"show","all","listen-port"]);if(ports==null)continue;
        for(let line in split(trim(ports),"\n")) {
            let found=match(line,/^([^[:space:]]+)[[:space:]]+([0-9]+)$/);
            if(found && int(found[2])>0) {known_interfaces[found[1]]=true;push(result.vpn_ports,int(found[2]));}
        }
        let endpoints=output([tool,"show","all","endpoints"]);if(endpoints==null)return null;
        for(let line in split(trim(endpoints),"\n")) {
            let parts=split(replace(trim(line),/[[:space:]]+/g," ")," ");
            if(length(parts)!=3 || parts[2]=="(none)")continue;
            let endpoint=match(parts[2],/^\[([^]]+)\]:([0-9]+)$/)||match(parts[2],/^([^:]+):([0-9]+)$/);
            if(!endpoint || !ip.valid_ip(endpoint[1]))return null;
            push(result.vpn,{ip:endpoint[1],port:int(endpoint[2])});
        }
    }
    // Native interface transports have no sing-box socket mark. Only active
    // WG/AWG sockets can currently be identified safely across endpoint roaming.
    for(let section in sections)if(common.bool_option(section,"enabled",true))
        for(let iface in require("config.connections").interfaces(section))
            if(!known_interfaces[iface])return null;
    return result;
}
function install(settings,sections,table,local4,local6,mark) {
    let selected=model.config(settings,sections);
    if(!selected.enabled)return true;
    if(selected.error)return false;
    let data=snapshot(settings,sections);if(!data) {warn("Router-origin bootstrap or native VPN transport could not be verified\n");return false;}
    let script=model.nft(table,local4,local6,mark,data);if(!script)return false;
    let path=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/router-origin.nft";
    let old=fs.lstat(path);if(old && old.type!="file")return false;
    let file=fs.open(path,"w",384);if(!file)return false;
    let saved=file.write(script)==length(script);file.close();
    let ok=saved && system("exec nft -f "+quote(path),15000)==0;fs.unlink(path);
    if(ok)require("singbox.failure_store").write((getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/router-origin.json",{section:selected.section,...data});
    return ok;
}
return {snapshot,install};
