// Router-origin capture is opt-in and has a distinct identity from LAN traffic.
let common=require("core.common"),ip=require("core.ip"),connections=require("config.connections"),tags=require("singbox.constants");
const MARK=0x10000000,PORT=1605;
const INBOUNDS=["router-tproxy-in","router-tproxy6-in"];
function number(value,fallback) {
    if(value==null)return fallback;
    if(type(value)=="int")return value;
    let text=lc(""+value),result=0;
    if(match(text,/^0x[0-9a-f]+$/)) {
        for(let n=2;n<length(text);n++)result=result*16+index("0123456789abcdef",substr(text,n,1));
        return result;
    }
    return match(text,/^[0-9]+$/)?int(text):-1;
}
function config(settings,sections,context) {
    if(!common.bool_option(settings,"router_origin_enabled",false))return {enabled:false};
    let name=common.option(settings,"router_origin_section",""),target=null;
    for(let section in sections||[])if(section[".name"]==name)target=section;
    if(!target || !common.bool_option(target,"enabled",true) || !connections.is_connections_action(target.action))
        return {enabled:true,section:name,error:"Router traffic requires an enabled Connection section"};
    context=context||{};
    for(let key in ["fakeip_mark","outbound_mark","mwan3_mask","zapret_mark","zapret2_mark"])
        if((number(context[key],0)&MARK)!=0)return {enabled:true,section:name,error:"Router-origin mark conflicts with another routing mark"};
    for(let section in sections||[])if(common.bool_option(section,"mixed_proxy_enabled",false) && number(section.mixed_proxy_port,0)==PORT)
        return {enabled:true,section:name,error:"Port 1605 is reserved for router traffic"};
    return {enabled:true,section:name};
}
function attach(value,settings,sections,context) {
    let selected=config(settings,sections,context);
    if(selected.error)die(selected.error+"\n");
    if(!selected.enabled)return value;
    for(let inbound in value.inbounds||[])if(inbound.listen_port==PORT)die("Port 1605 is reserved for router traffic\n");
    for(let family=0;family<2;family++)push(value.inbounds,{type:"tproxy",tag:INBOUNDS[family],listen:family?"::1":"127.0.0.1",listen_port:PORT});
    let origin={kind:"router",section:selected.section};
    for(let rule in value.route.rules)if(rule.action=="sniff") {
        let inbounds=type(rule.inbound)=="array"?rule.inbound:[rule.inbound];
        rule.inbound=[...inbounds,...INBOUNDS];break;
    }
    // System sniff/DNS hijack precede this rule; LAN rules never decide router traffic.
    splice(value.route.rules,2,0,{action:"route",inbound:INBOUNDS,outbound:tags.outbound_tag(selected.section),__trafira_origin:origin});
    unshift(value.dns.rules,{action:"route",inbound:INBOUNDS,server:tags.DNS_SERVER_TAG,__trafira_origin:origin});
    return value;
}
function nft(table,local4,local6,route_mark,snapshot) {
    for(let id in [table,local4,local6])if(type(id)!="string" || !match(id,/^[A-Za-z_][A-Za-z0-9_]*$/))return null;
    let mark=number(route_mark,-1);if(mark<=0 || (mark&MARK)!=0)return null;
    snapshot=snapshot||{};
    let prefix=" inet "+table+" ",text="add chain"+prefix+"router_exempt\nadd chain"+prefix+"router_origin\n";
    function rule(chain,body){text+="add rule"+prefix+chain+" "+body+"\n";}
    // accept terminates this output base chain, preserving existing service transports.
    rule("router_exempt","meta mark != 0 return");
    rule("router_exempt","ct direction reply accept");
    rule("router_exempt","oifname \"lo\" accept");
    rule("router_exempt","ip daddr @"+local4+" accept");
    rule("router_exempt","ip6 daddr @"+local6+" ip6 daddr != "+tags.FAKEIP_INET6_RANGE+" accept");
    rule("router_exempt","ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept");
    rule("router_exempt","ip6 daddr ff02::1:2 udp sport 546 udp dport 547 accept");
    for(let family in [4,6])for(let kind in ["dns","ntp"]) {
        let addresses=[];
        for(let address in snapshot[kind]||[]) {
            if(!ip.valid_ip(address))return null;
            if(ip.ip_family(address)==family && index(addresses,address)<0)push(addresses,address);
        }
        if(length(addresses)>256)return null;
        let name="router_"+kind+family;
        text+="add set"+prefix+name+" { type ipv"+family+"_addr; }\n";
        if(length(addresses))text+="add element"+prefix+name+" { "+join(", ",addresses)+" }\n";
        rule("router_exempt",(family==4?"ip":"ip6")+" daddr @"+name+" "+(kind=="dns"?"meta l4proto { tcp, udp } th dport { 53 }":"udp dport { 123 }")+" accept");
    }
    for(let endpoint in snapshot.vpn||[]) {
        if(!ip.valid_ip(endpoint.ip) || type(endpoint.port)!="int" || endpoint.port<1 || endpoint.port>65535)return null;
        rule("router_exempt",(ip.ip_family(endpoint.ip)==4?"ip":"ip6")+" daddr "+endpoint.ip+" udp dport "+endpoint.port+" accept");
    }
    for(let port in snapshot.vpn_ports||[]) {
        if(type(port)!="int" || port<1 || port>65535)return null;
        // These ports are read from active kernel WG/AWG sockets, never user settings.
        rule("router_exempt","udp sport "+port+" accept");
    }
    text+="insert rule"+prefix+"mangle_output jump router_exempt\n";
    rule("router_origin","ct direction reply return");
    rule("router_origin","meta mark != 0 return");
    rule("router_origin","meta l4proto { tcp, udp } meta mark set "+sprintf("0x%08x",mark|MARK)+" counter");
    rule("mangle_output","jump router_origin");
    // Insert ahead of generic LAN TPROXY; accept prevents a second listener assignment.
    for(let family in [4,6])text+="insert rule"+prefix+"proxy iifname \"lo\" meta mark & "+sprintf("0x%08x",MARK|mark)+" == "+sprintf("0x%08x",MARK|mark)+" meta l4proto { tcp, udp } tproxy "+(family==4?"ip to 127.0.0.1:1605":"ip6 to [::1]:1605")+" counter accept\n";
    return text;
}
return {config,attach,nft,MARK,PORT,INBOUNDS};
