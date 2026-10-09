let policy=require("singbox.failure_policy"),constants=require("singbox.constants");
function array(value){return type(value)=="array"?value:[];}
function copy(value){return json(sprintf("%J",value));}
function target(section,state) {
    let p=policy.from_section(section),mode=state?state.mode:"blocked";
    if(mode=="primary")return constants.outbound_tag(section[".name"]);
    if(mode=="direct" && p.mode=="direct")return constants.BYPASS_OUTBOUND_TAG;
    if(mode=="reserve" && p.mode=="reserve")return constants.outbound_tag(p.reserve_section);
    return "";
}
function reject(rule) {
    for(let key in ["outbound","server","strategy","rewrite_ttl","disable_cache","disable_optimistic_cache","timeout","client_subnet","remove_client_subnet","tag","speculative","race"])
        delete rule[key];
    rule.action="reject";
}
function apply(baseline,sections,states) {
    let config=copy(baseline),managed={},by_outbound={},dns_servers={},clones={};
    for(let section in sections||[]) {
        let p=policy.from_section(section);
        if(p.mode=="legacy")continue;
        let name=section[".name"];
        managed[name]={section,outbound:target(section,(states||{})[name])};
        by_outbound[constants.outbound_tag(name)]=managed[name];
    }
    for(let server in array(config.dns.servers))dns_servers[server.tag]=server;
    function dns_target(rule,item) {
        if(!item.outbound) {reject(rule);return;}
        let server=dns_servers[rule.server];
        if(!server) {reject(rule);return;}
        if(index(["fakeip","hosts"],server.type)>=0)return;
        // Local/dhcp resolvers cannot be constrained to a protected outbound.
        // Refuse the matching DNS request rather than silently leak it.
        if(index(["udp","tcp","tls","https","quic","http3"],server.type)<0) {reject(rule);return;}
        let key=item.section[".name"]+"|"+server.tag;
        if(!clones[key]) {
            let clone=copy(server),tag="failure-"+item.section[".name"]+"-dns-"+length(keys(clones));
            if(dns_servers[tag]) {reject(rule);return;}
            clone.tag=tag;clone.detour=item.outbound;
            push(config.dns.servers,clone);clones[key]=tag;dns_servers[tag]=clone;
        }
        rule.server=clones[key];
    }
    for(let rule in array(config.route.rules)) {
        let origin=rule.__trafira_origin||{},item=by_outbound[rule.outbound]||managed[origin.section];
        if(!item)continue;
        if(rule.action=="route") {
            if(item.outbound)rule.outbound=item.outbound;
            else reject(rule);
        } else if(rule.action=="resolve") {
            rule.server=rule.server||constants.DNS_SERVER_TAG;
            dns_target(rule,item);
        }
    }
    for(let rule in array(config.dns.rules)) {
        let item=managed[(rule.__trafira_origin||{}).section];
        if(!item)continue;
        if(index(["route","evaluate","respond"],rule.action||"route")>=0)dns_target(rule,item);
    }
    return config;
}
return {apply,target};
