let fs = require("fs");
let common = require("core.common");
let uci = require("core.uci");
let ip = require("core.ip");
let alice = require("config.alice");
let matcher = require("diagnostics.route_match");
let provenance = require("singbox.provenance");
let arr = common.array_or_empty, obj = common.object_or_empty;
let read_guard=null;
function quote(value) { return "'" + replace(common.as_string(value), /'/g, "'\\''") + "'"; }
function read_json(path, limit) {
    let info = fs.stat(path);
    if (!info || info.type != "file" || info.size > limit) return null;
    let file = fs.open(path,"r");
    if (!file) return null;
    let raw = file.read(limit+1); file.close();
    if (length(raw || "") > limit) return null;
    try { return json(raw); } catch (e) { return null; }
}
function error(reason) { return {success:false,error:reason}; }
function validate(raw) {
    if (type(raw) != "string" || length(raw) > 8192) return null;
    let r; try { r=json(raw); } catch (e) { return null; }
    if (type(r) != "object" || type(r.domain) != "string" || length(r.domain)>253 ||
        !match(r.domain,/^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9.])?$/) || index(r.domain,"..")>=0 ||
        type(r.port)!="int" || r.port<1 || r.port>65535 || index(["tcp","udp"],r.network)<0) return null;
    for (let key in r)
        if (index(["domain","source","destination_ip","port","network","protocol"],key)<0) return null;
    if (r.destination_ip != null && (type(r.destination_ip)!="string" || !ip.valid_ip(r.destination_ip))) return null;
    if (r.protocol != null && index(["tls","http","quic","dns","bittorrent","ssh","stun"],r.protocol)<0) return null;
    if (type(r.source)!="object" || index(["device","router"],r.source.kind)<0) return null;
    for (let key in r.source)
        if (index(["kind","ip","mac","interface"],key)<0) return null;
    if (r.source.kind=="device" && (type(r.source.ip)!="string" || !ip.valid_ip(r.source.ip))) return null;
    if (r.source.mac!=null && (type(r.source.mac)!="string" || !ip.valid_mac(r.source.mac))) return null;
    if (r.source.interface!=null && (type(r.source.interface)!="string" || length(r.source.interface)>64 || !match(r.source.interface,/^[A-Za-z0-9_.@-]+$/))) return null;
    return r;
}
function decision(status, reason) { return {status,outbound:status=="direct"?"bypass-out":null,trace:[],missing:reason?[reason]:[]}; }
function gate(settings,r,config) {
    if (r.source.kind=="router") {
        if(!r.destination_ip)return decision("indeterminate","router_destination_address_needed");
        if(!common.bool_option(settings,"router_origin_enabled",false))return decision("indeterminate","legacy_router_output_rules");
        if(!filter(arr(config.inbounds),(inbound)=>inbound.tag=="router-tproxy-in")[0])return decision("indeterminate","router_settings_not_applied");
        let constants=require("core.constants");
        if(system("nft list chain inet "+quote(constants.NFT_TABLE_NAME)+" router_origin >/dev/null 2>&1",2000)!=0)
            return decision("indeterminate","router_capture_not_running");
        let snapshot=read_json((getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/router-origin.json",65536);
        if(!snapshot || snapshot.section!=settings.router_origin_section)return decision("indeterminate","router_bootstrap_snapshot_unavailable");
        for(let cidr in ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"])
            if(ip.ip_in_cidr(r.destination_ip,cidr) && !ip.ip_in_cidr(r.destination_ip,"fc00::/18"))return decision("indeterminate","local_destination_check_nft_exclusions");
        if(r.port==53 && index(arr(snapshot.dns),r.destination_ip)>=0)return decision("direct","router_bootstrap_dns");
        if(r.network=="udp" && r.port==123 && index(arr(snapshot.ntp),r.destination_ip)>=0)return decision("direct","router_bootstrap_ntp");
        for(let endpoint in arr(snapshot.vpn))if(r.network=="udp" && endpoint.ip==r.destination_ip && endpoint.port==r.port)
            return decision("direct","router_vpn_transport");
        return null;
    }
    let a=alice.config(settings), device={ips:[r.source.ip],mac:r.source.mac,interface:r.source.interface};
    if (a.enabled) {
        let matched=alice.match_device(a,device);
        if (!matched && ((!r.source.interface && length(a.interfaces)) || (!r.source.mac && length(a.macs))))
            return decision("indeterminate","alice_device_details_missing");
        if (!alice.routes_through_trafira(a,matched)) return decision("direct","alice_bypass");
    }
    let interfaces=common.list_option(settings,"source_network_interfaces");
    if (length(interfaces)) {
        if (!r.source.interface) return decision("indeterminate","incoming_interface_missing");
        if (!alice.interface_in_list(interfaces,r.source.interface)) return decision("direct","interface_not_captured");
    }
    if (r.destination_ip) {
        for (let cidr in ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"])
            if (ip.ip_in_cidr(r.destination_ip,cidr)) return decision("indeterminate","local_destination_check_nft_exclusions");
    }
    if (common.bool_option(settings,"exclude_wifi_calling",false) && r.network=="udp" && (r.port==500 || r.port==4500))
        return decision("indeterminate","wifi_calling_bypass_depends_on_real_destination");
    return null;
}
function decode_set(path,format) {
    let info=fs.stat(path);
    if (!info || info.type!="file" || info.size>4194304) return null;
    let pipe=fs.popen("umask 077; mktemp /tmp/trafira-explain.XXXXXX","r");
    if (!pipe) return null;
    let temporary=trim(pipe.read(256)||"");
    if (pipe.close()!=0 || !match(temporary,/^\/tmp\/trafira-explain[.][A-Za-z0-9]+$/)) return null;
    // The watchdog must not inherit the RPC output streams: its sleep child
    // can outlive the killed shell, preventing file.exec from receiving EOF.
    // Bound both output size and runtime; OpenWrt does not always provide timeout.
    let command="(ulimit -f 8192; exec sing-box rule-set " + (format=="source"?"compile":"decompile") + " " + quote(path) + " -o " + quote(temporary) +
        " >/dev/null 2>&1) & child=$!; (sleep 3; kill -TERM \"$child\" 2>/dev/null) >/dev/null 2>&1 & guard=$!; " +
        "wait \"$child\"; code=$?; kill \"$guard\" 2>/dev/null; wait \"$guard\" 2>/dev/null; exit \"$code\"";
    // Compile validates source copies against the installed core's accepted
    // schema/version; only binary copies need their temporary decoded output.
    let status=system(command), data=status==0 ? read_json(format=="source"?path:temporary,4194304) : null;
    fs.unlink(temporary);
    return data;
}
function load_sets(config,limitations) {
    let sets={}, decoded={}, used=0, started=time(), available=0, unavailable=0, remote=false, saved=false, unavailable_reasons=[];
    let cache=require("singbox.ruleset_cache");
    for (let rule in arr(obj(config.route).rule_set)) {
        if (type(rule.tag)!="string") continue;
        let reason=null;
        if (rule.type=="inline") {
            sets[rule.tag]=type(rule.rules)=="array"?{rules:rule.rules}:null;
            if (sets[rule.tag]==null) reason="decode_failed";
        }
        else {
            // The snapshot identity includes the exact applied URL and format.
            // A same-tag copy from another URL must never decide this scenario.
            let path=rule.type=="remote"?cache.path(rule):rule.type=="local"?rule.path:null;
            if (rule.type=="remote") remote=true;
            let key=common.as_string(path)+"\n"+(rule.format||"binary");
            if (decoded[key]!=null) sets[rule.tag]=decoded[key];
            else {
                let info=type(path)=="string" && path!=""?(rule.type=="local"?fs.stat(path):fs.lstat(path)):null;
                if (!info || info.type!="file" || info.size<=0) {sets[rule.tag]=null;reason="missing";}
                else if (info.size>4194304) {sets[rule.tag]=null;reason="limit";}
                else if (used+info.size>8388608 || time()-started>=6) {
                    sets[rule.tag]=null;reason="limit";
                    if (index(limitations,"rule_set_loading_limit")<0) push(limitations,"rule_set_loading_limit");
                }
                else {
                    used+=info.size;
                    let digest=provenance.hash_file(path);
                    let data=decode_set(path,rule.format);
                    let same=digest && digest==provenance.hash_file(path);
                    sets[rule.tag]=same && type(data)=="object" && type(data.rules)=="array"?data:null;
                    if (sets[rule.tag]==null) reason=digest && !same?"changed":"decode_failed";
                    if (sets[rule.tag]!=null) decoded[key]=sets[rule.tag];
                }
            }
            if (rule.type=="remote" && sets[rule.tag]!=null) saved=true;
        }
        if (sets[rule.tag]!=null) available++;
        else {
            unavailable++;
            if (length(unavailable_reasons)<200) push(unavailable_reasons,{tag:rule.tag,reason:reason||"decode_failed"});
        }
    }
    // Successful decoding proves a usable saved copy, not the bytes in memory.
    // sing-box may have loaded its own cache or updated a remote set meanwhile.
    if (saved) push(limitations,"saved_rule_sets_may_differ_from_running_core");
    return {sets,report:{basis:remote?"saved_snapshots":"local",live_verified:false,available,unavailable,unavailable_reasons}};
}
function selected_node(config,tag) {
    let out=filter(arr(config.outbounds),(o)=>o.tag==tag)[0];
    if (!out || index(["selector","urltest"],out.type)<0) return null;
    let api=obj(obj(config.experimental).clash_api);
    let port=match(api.external_controller || "", /^(127[.]0[.]0[.]1|0[.]0[.]0[.]0):([0-9]+)$/);
    if (!port || int(port[2])<1 || int(port[2])>65535 || !match(tag,/^[A-Za-z0-9_-]+$/)) return null;
    let args=["curl","--fail","--silent","--noproxy","*","--max-time","2","--max-filesize","65536"];
    if (api.secret) push(args,"-H","Authorization: Bearer " + api.secret);
    push(args,"http://127.0.0.1:" + port[2] + "/proxies/" + tag);
    let pipe=fs.popen(join(" ",map(args,quote))+" 2>/dev/null","r");
    if (!pipe) return null;
    let raw=pipe.read(65537), status=pipe.close();
    if (status!=0 || length(raw||"")>65536) return null;
    try {
        let data=json(raw);
        return type(data.now)=="string" && index(arr(out.outbounds),data.now)>=0 ? {tag,current:substr(data.now,0,256)} : null;
    } catch (e) { return null; }
}
function fake_destination(config,address) {
    if(!address)return false;
    let ranges=[];
    for(let server in arr(obj(config.dns).servers))if(server.type=="fakeip")
        push(ranges,server.inet4_range||"198.18.0.0/15",server.inet6_range||"fc00::/18");
    let legacy=obj(obj(config.dns).fakeip);
    if(legacy.enabled)push(ranges,legacy.inet4_range||"198.18.0.0/15",legacy.inet6_range||"fc00::/18");
    return length(filter(ranges,(range)=>ip.ip_in_cidr(address,range)))>0;
}
function explain(raw) {
    let r=validate(raw); if (!r) return error("invalid_request");
    let root=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira",lockinfo=fs.lstat(root+"/operation.lock");
    if(lockinfo && lockinfo.type=="file")read_guard=fs.open(root+"/operation.lock","re");
    let locked=read_guard && read_guard.lock("sn");
    let applied=locked?require("service.applied_config").active():null;
    let settings=applied?applied.settings:obj(uci.get_all("trafira","settings")),path=common.option(settings,"config_path","");
    let lib=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
    let active=applied && system("exec ucode -L "+quote(lib)+" "+quote(lib+"/service/state.uc")+" sing-box-service-running >/dev/null 2>&1",3000)==0 &&
        system("nft list table inet "+quote(require("core.constants").NFT_TABLE_NAME)+" >/dev/null 2>&1",2000)==0;
    if (path=="") return error("configuration_unavailable");
    let digest=provenance.hash_file(path), config=read_json(path,4194304);
    if (!digest || type(config)!="object") return error("configuration_unavailable");
    let origins=provenance.load(path), limitations=["scenario_not_packet_capture"];
    if (!origins) push(limitations,"provenance_unavailable");
    let loaded=load_sets(config,limitations),sets=loaded.sets;
    let request={domain:lc(r.domain),source_ip:r.source.ip,destination_ip:r.destination_ip,port:r.port,network:r.network,
        protocol:r.protocol,source_mac_address:r.source.mac,inbound:r.source.kind=="router"?(ip.ip_family(r.destination_ip)==6?"router-tproxy6-in":"router-tproxy-in"):(ip.ip_family(r.source.ip)==6?"tproxy6-in":"tproxy-in")};
    let route=!active?decision("indeterminate","applied_capture_state_unavailable"):fake_destination(config,r.destination_ip)?decision("indeterminate","fakeip_is_not_real_destination"):gate(settings,r,config) || matcher.explain(config,request,origins || {},sets);
    let dns_request={domain:request.domain,source_ip:request.source_ip,query_type:"A"};
    if(r.source.kind=="device")dns_request.inbound=require("singbox.constants").SOURCE_DNS_INBOUND_TAG;
    if(r.source.kind=="router") {
        if(common.bool_option(settings,"router_origin_enabled",false)) {
            dns_request.inbound=request.inbound;
            push(limitations,"router_assumes_unmarked_application_original_direction");
        }
        else {
            // Legacy router DNS reaches the ordinary dnsmasq forwarding listener,
            // not the opt-in router TPROXY listener absent from this config.
            dns_request.inbound=require("singbox.constants").DNS_INBOUND_TAG;
            push(limitations,"router_dns_assumes_local_forwarder");
        }
    }
    let dns=active?matcher.explain({route:obj(config.dns)},dns_request,{route:obj(origins).dns},sets):decision("indeterminate","applied_capture_state_unavailable");
    let selected=route.outbound ? selected_node(config,route.outbound) : null;
    if (digest!=provenance.hash_file(path)) return error("configuration_changed_retry");
    return {success:true,generated_at:time(),config_digest:digest,decision:route,dns_policy:dns,
        dns_query:{performed:false,origin:"none"},selector:selected,rule_sets:loaded.report,limitations};
}
print(sprintf("%J\n",ARGV[0]=="explain" ? explain(ARGV[1]) : error("invalid_command")));
