// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),transport=require("warp.transport"),process=require("warp.process");
const ACCOUNT=state.DIRECTORY+"/account.json",CANDIDATE=state.RUNTIME+"/candidate.json";
const SCOUT="/usr/libexec/trafira-warp-scout";
function account_valid(a) {
    if(type(a)!="object" || type(a.id)!="string" || !match(a.id,/^[A-Za-z0-9._-]{8,128}$/) || type(a.token)!="string" || !match(a.token,/^[A-Za-z0-9._~+\/=-]{1,4096}$/))return false;
    for(let key in ["private_key","peer_public_key"])if(type(a[key])!="string" || !match(a[key],/^[A-Za-z0-9+\/]{43}=$/))return false;
    return transport.ipv4(a.ipv4) && (!a.ipv6 || transport.ipv6(a.ipv6)) && !a.outer && !a.masque;
}
function digest() {
    let text=transport.output(["sha256sum",ACCOUNT]),found=match(text||"",/^([a-f0-9]{64}) /);return found?found[1]:null;
}
function parse_candidate(text,account,iface,mark) {
    let fail={success:false,error:"invalid_candidate"};
    if(type(text)!="string" || length(text)>65536 || !account_valid(account))return fail;
    let values={},section="",sections={};
    for(let line in split(text,"\n")) {
        line=trim(line);if(!length(line) || substr(line,0,1)=="#")continue;
        if(line=="[Interface]" || line=="[Peer]") {if(sections[line])return fail;sections[line]=true;section=line;continue;}
        let found=match(line,/^([A-Za-z0-9]+)\s*=\s*(.+)$/);if(!found || !section || values[found[1]]!=null)return fail;
        let allowed=section=="[Interface]"?["PrivateKey","Address","DNS","Table","MTU","Jc","Jmin","Jmax","I1"]:["PublicKey","Endpoint","AllowedIPs","PersistentKeepalive"];
        if(index(allowed,found[1])<0 || match(found[2],/[\r\n]/))return fail;
        values[found[1]]=trim(found[2]);
    }
    if(values.PrivateKey!=account.private_key || values.PublicKey!=account.peer_public_key || values.AllowedIPs!="0.0.0.0/0, ::/0" || (values.Table && values.Table!="off"))return fail;
    for(let key in ["Jc","Jmin","Jmax"])if(!match(values[key]||"",/^[0-9]+$/))return fail;
    let config={interface:iface,endpoint:values.Endpoint,fwmark:mark,mtu:1280,private_key:account.private_key,peer_public_key:account.peer_public_key,
        ipv4:account.ipv4,ipv6:account.ipv6,jc:int(values.Jc),jmin:int(values.Jmin),jmax:int(values.Jmax),i1:values.I1,enabled:false};
    return transport.valid_config(config)?{success:true,config}:fail;
}
function candidate_current(candidate,account_digest,generation,now) {
    return type(candidate)=="object" && candidate.account_digest==account_digest && candidate.generation==generation && candidate.expires_at>now;
}
function register(id,mark) {
    let existing=state.load(ACCOUNT);if(fs.lstat(ACCOUNT) && !existing)return {success:false,error:"invalid_account"};
    if(existing)return account_valid(existing)?{success:true,registered:true}:{success:false,error:"invalid_account"};
    if(mark!=134217728 || !state.ensure(state.DIRECTORY))return {success:false,error:"invalid_transport"};
    let target=state.DIRECTORY+"/registration.json";
    if(fs.lstat(target)) {
        let pending=state.load(target);
        if(!account_valid(pending) || !state.save(ACCOUNT,pending))return {success:false,error:"registration_incomplete"};
        state.remove(target);return {success:true,registered:true};
    }
    let result=process.run(["env","GOMAXPROCS=1","GOMEMLIMIT=24MiB","NO_COLOR=1",SCOUT,"register","--fwmark",""+mark,"--plain","--relay","none","--account",target,"--gen-i1","quic","--i1-sni","www.google.com"],120,id);
    // A completed remote registration is retained even if later discovery fails.
    let account=state.load(target);
    if(account_valid(account) && state.save(ACCOUNT,account)){state.remove(target);return {success:true,registered:true};}
    return {success:false,error:result.success?"invalid_account":result.error};
}
function run(mode,mark,id) {
    if(index(["quick","full"],mode)<0 || mark!=134217728)return {success:false,error:"invalid_request"};
    let account=state.load(ACCOUNT);if(!account_valid(account))return {success:false,error:"registration_required"};
    let old=state.load(state.DIRECTORY+"/transport.json"),iface=old?.interface;
    if(!iface)iface=transport.choose_interface(require("uci").cursor().get_all("network")||{},fs.lsdir("/sys/class/net")||[]);
    if(!iface)return {success:false,error:"interface_conflict"};
    let target=state.RUNTIME+"/scout.conf";if(!state.remove(target))return {success:false,error:"storage_unavailable"};
    let result=process.run(["env","GOMAXPROCS=1","GOMEMLIMIT=24MiB","NO_COLOR=1",SCOUT,"scan","--fwmark",""+mark,"--plain","--account",ACCOUNT,"--proto","awg",
        "--gen-i1","quic","--i1-sni","www.google.com","--sample",mode=="quick"?"5":"32","--tunnel-jobs","1","--tun-ping-count","10","--ping-target","8.8.8.8",
        "--no-report","--conf",target,"--table-off","--no-dns","--mtu","1280","--target","162.159.192.0/24,188.114.96.0/24,188.114.97.0/24"],mode=="quick"?180:900,id);
    if(!result.success)return {success:false,error:result.error};
    let info=fs.lstat(target);if(!info || info.type!="file" || info.size>65536)return {success:false,error:"invalid_candidate"};
    let parsed=parse_candidate(fs.readfile(target),account,iface,mark);state.remove(target);if(!parsed.success)return parsed;
    let candidate={candidate_id:"c-"+id,config:parsed.config,account_digest:digest(),generation:old?.generation||0,expires_at:clock()[0]+900};
    if(!candidate.account_digest || !state.save(CANDIDATE,candidate))return {success:false,error:"storage_unavailable"};
    return {success:true,candidate_id:candidate.candidate_id};
}
function pick(id) {
    let candidate=state.load(CANDIDATE),current=state.load(state.DIRECTORY+"/transport.json");
    if(!candidate || candidate.candidate_id!=id || !candidate_current(candidate,digest(),current?.generation||0,clock()[0]))return {success:false,error:"stale_candidate"};
    return {success:true,config:{...candidate.config,enabled:current?.enabled===true}};
}
return {account_valid,parse_candidate,candidate_current,digest,register,run,pick};
