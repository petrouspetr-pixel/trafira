let ip=require("core.ip");

function public_resolver(value) {
    if(!ip.valid_ip(value))return false;
    for(let network in ["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","198.18.0.0/15","224.0.0.0/3","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"])
        if(ip.ip_in_cidr(value,network))return false;
    return true;
}
function lookup(host,server,query) {
    let seen={},answered=false;
    for(let kind in ["A","AAAA"]) {
        let result=query(host,kind,server);
        if(!result || result.status!=0)continue;
        // dig returns zero even for SERVFAIL/REFUSED. An authoritative empty
        // answer is usable, but a resolver failure must allow the next server.
        let status=match(result.output||"",/status: ([A-Z]+)/);
        if(status && status[1]!="NOERROR" && status[1]!="NXDOMAIN")continue;
        answered=true;
        for(let line in split(result.output||"","\n")) {
            line=trim(line);
            if(ip.valid_ip(line))seen[line]=true;
        }
    }
    return {answered,ips:join(" ",sort(keys(seen)))};
}
function resolve(host,servers,query) {
    host=trim(""+(host||""));
    if(substr(host,0,1)=="[" && substr(host,-1)=="]")host=substr(host,1,length(host)-2);
    if(host=="" || ip.valid_ip(host))return host;
    let selected=[];
    for(let entry in servers||[])
        for(let server in split(trim(""+entry),/\s+/))
            if(public_resolver(server) && index(selected,server)<0 && length(selected)<2)push(selected,server);
    if(!length(selected))selected=["1.1.1.1","8.8.8.8"];
    for(let server in selected) {
        let result=lookup(host,server,query);
        if(result.answered)return result.ips;
    }
    return lookup(host,"",query).ips;
}
return {resolve};
