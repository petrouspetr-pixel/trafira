// Ordinary LuCI reloads already committed UCI. Roll back to the last verified
// checkpoint on failure; protect traffic even while the main nft table is absent.
let fs=require("fs"),common=require("core.common"),ip=require("core.ip"),transaction=require("service.config_transaction"),hash=require("singbox.provenance").hash_file;
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function guard_script(settings,previous,snapshot){
    settings=settings||{};previous=previous||{};snapshot=snapshot||{};
    let interfaces=[];
    for(let item in [settings,previous]) {
        let names=common.list_option(item,"source_network_interfaces");if(!length(names))names=["br-lan"];
        for(let name in names){if(!match(name,/^[A-Za-z0-9_.@-]+\*?$/))return null;if(index(interfaces,name)<0)push(interfaces,name);}
    }
    let text="add table inet TrafiraReloadGuard\nflush table inet TrafiraReloadGuard\n"+
        "add chain inet TrafiraReloadGuard forward { type filter hook forward priority -200; policy accept; }\n";
    for(let name in interfaces)text+="add rule inet TrafiraReloadGuard forward iifname \""+name+"\" counter drop\n";
    text+="add chain inet TrafiraReloadGuard input { type filter hook input priority -151; policy accept; }\n"+
        "add rule inet TrafiraReloadGuard input meta l4proto { tcp, udp } th dport { 1602, 1603, 1604, 1605 } counter drop\n"+
        "add rule inet TrafiraReloadGuard input ip daddr 127.0.0.42 meta l4proto { tcp, udp } th dport 53 counter drop\n";
    if(common.bool_option(settings,"router_origin_enabled",false) || common.bool_option(previous,"router_origin_enabled",false)) {
        text+="add chain inet TrafiraReloadGuard output { type filter hook output priority -149; policy accept; }\n";
        let prefix="add rule inet TrafiraReloadGuard output ";
        text+=prefix+"meta mark != 0 return\n"+prefix+"ct direction reply return\n"+prefix+"oifname \"lo\" return\n";
        text+=prefix+"ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return\n";
        text+=prefix+"ip6 daddr fc00::/18 counter drop\n"+prefix+"ip6 daddr { ::1/128, fc00::/7, fe80::/10 } return\n";
        text+=prefix+"ip daddr 255.255.255.255 udp sport 68 udp dport 67 return\n"+prefix+"ip6 daddr ff02::1:2 udp sport 546 udp dport 547 return\n";
        for(let kind in ["dns","ntp"])for(let address in snapshot[kind]||[]) {
            if(!ip.valid_ip(address))return null;
            text+=prefix+(ip.ip_family(address)==4?"ip":"ip6")+" daddr "+address+" "+(kind=="dns"?"meta l4proto { tcp, udp } th dport 53":"udp dport 123")+" return\n";
        }
        for(let port in snapshot.vpn_ports||[]) {if(type(port)!="int" || port<1 || port>65535)return null;text+=prefix+"udp sport "+port+" return\n";}
        text+=prefix+"meta l4proto { tcp, udp } counter drop\n";
    }
    return text;
}
function guard(settings,previous,snapshot){
    let text=guard_script(settings,previous,snapshot);if(!text)return false;
    let path=ROOT+"/reload-guard.nft",old=fs.lstat(path);if(old && old.type!="file")return false;
    let file=fs.open(path,"we",384);if(!file)return false;
    let ok=file.write(text)==length(text);file.close();
    ok=ok && system("exec nft -f "+quote(path),10000)==0;fs.unlink(path);return ok;
}
function clear(){
    if(system("nft list table inet TrafiraReloadGuard >/dev/null 2>&1",2000)!=0)return true;
    return system("nft delete table inet TrafiraReloadGuard",10000)==0;
}
function apply(previous,settings,hooks){
    if(!previous || type(previous.config_text)!="string")return {success:false,error:"applied_checkpoint_unavailable"};
    if(!hooks.guard())return {success:false,error:"reload_guard_failed"};
    let result=transaction.apply(transaction.TARGET,hash(transaction.TARGET),"runtime-reload",{...hooks,original:previous.config_text});
    if(result.success || result.restored) {
        if(!hooks.clear())return {...result,success:false,error:"reload_guard_clear_failed",guarded:true};
    }
    return result;
}
function prepare_bootstrap(data){
    return require("singbox.failure_store").write(ROOT+"/router-bootstrap-prepared.json",{worker:require("service.operation_lock").identity(),config_text:require("service.applied_config").normalized(fs.readfile(transaction.TARGET)),data});
}
return {apply,guard_script,guard,clear,prepare_bootstrap};
