// Resolve a bounded scenario through Trafira's real main DNS, never system/public DNS.
let fs=require("fs"),ip=require("core.ip"),common=require("core.common");
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function fake(config,address){
    let ranges=[];
    for(let server in common.array_or_empty((config.dns||{}).servers))if(server.type=="fakeip")
        push(ranges,server.inet4_range||"198.18.0.0/15",server.inet6_range||"fc00::/18");
    let legacy=(config.dns||{}).fakeip||{};
    if(legacy.enabled)push(ranges,legacy.inet4_range||"198.18.0.0/15",legacy.inet6_range||"fc00::/18");
    return length(filter(ranges,(range)=>ip.ip_in_cidr(address,range)))>0;
}
function resolve(config,request,settings,workspace){
    if(request.destination_ip)return {performed:false,origin:"manual",status:"provided",addresses:[request.destination_ip],truncated:false};
    if(ip.valid_ip(request.domain))return {performed:false,origin:"literal",status:"provided",addresses:[request.domain],truncated:false};
    let result={performed:false,origin:"trafira_main_dns",status:"unavailable",addresses:[],truncated:false};
    let inbound=filter(common.array_or_empty(config.inbounds),(item)=>item.tag=="dns-health-active-main-in" && item.listen=="127.0.0.42" && item.listen_port==12053)[0];
    if(!inbound)return result;
    let strategy=(config.dns||{}).strategy||settings.dns_strategy||"prefer_ipv4",family=request.source.kind=="device"?ip.ip_family(request.source.ip):0;
    let types=family==4 || strategy=="ipv4_only"?["A"]:family==6 || strategy=="ipv6_only"?["AAAA"]:strategy=="prefer_ipv6"?["AAAA","A"]:["A","AAAA"];
    result.family=length(types)==2?"both":types[0]=="A"?"ipv4":"ipv6";
    let temporary=workspace?workspace+"/dns-answer":null;
    if(!temporary){
        let pipe=fs.popen("umask 077; mktemp /tmp/trafira-route-dns.XXXXXX","re");
        temporary=pipe?trim(pipe.read(256)||""):"";
        if(!pipe || pipe.close()!=0 || !match(temporary,/^\/tmp\/trafira-route-dns[.][A-Za-z0-9]+$/))return result;
    } else {
        let file=fs.open(temporary,"wex",384);if(!file)return result;file.close();
    }
    let failed=false,timed_out=false,fake_seen=false;
    try {
        for(let type in types){
            let args=["dig","@127.0.0.42","-p","12053",request.domain,type,"+short","+tcp","+timeout=2","+tries=1","+nosearch"];
            result.performed=true;
            let code=system("ulimit -f 128; exec "+join(" ",map(args,quote))+" >"+quote(temporary)+" 2>/dev/null",3000);
            let info=fs.lstat(temporary);
            if(code!=0 || !info || info.type!="file" || info.size>65536){failed=true;if(code==-9 || code==9)timed_out=true;continue;}
            for(let line in split(fs.readfile(temporary)||"","\n")){
                let address=trim(line);
                if(!ip.valid_ip(address) || ip.ip_family(address)!=(type=="A"?4:6))continue;
                if(fake(config,address)){fake_seen=true;continue;}
                if(index(result.addresses,address)>=0)continue;
                if(length(result.addresses)==4){result.truncated=true;continue;}
                push(result.addresses,address);
            }
        }
    } catch(e) {failed=true;}
    fs.unlink(temporary);
    // A failed second-family lookup must not imply that all possible routes agree.
    result.partial=failed && length(result.addresses)>0;
    result.status=length(result.addresses)?"resolved":fake_seen?"fakeip":timed_out?"timeout":failed?"failed":"no_address";
    return result;
}
return {resolve,fake};
