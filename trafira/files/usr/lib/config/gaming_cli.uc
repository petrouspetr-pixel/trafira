let fs=require("fs"),g=require("config.gaming_presets"),jobs=require("config.profile_job"),runtime=require("config.profile_runtime");
let format=require("config.profile_format"),transaction=require("service.config_transaction"),locks=require("service.operation_lock");
let hash=require("singbox.provenance").hash_file,common=require("core.common"),matcher=require("diagnostics.route_match");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const CATALOG=getenv("TRAFIRA_GAMING_CATALOG")||"/usr/share/trafira/gaming-presets.json";
function fail(error){return {success:false,error};}
function read(path,limit){
    let stat=fs.lstat(path);if(!stat || stat.type!="file" || stat.size>limit)return null;
    try{return json(fs.readfile(path));}catch(e){return null;}
}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function devices(directory){
    let output=directory+"/devices.json";
    let command=join(" ",map(["ucode","-L",LIB,LIB+"/diagnostics/alice.uc","get-known-devices"],quote));
    if(system("exec "+command+" >"+quote(output)+" 2>/dev/null",10000)!=0)return [];
    let result=read(output,1048576);
    return filter(type(result.devices)=="array"?result.devices:[],(device)=>type(device.mac)=="string" && length(device.mac)>0);
}
function checks(directory,request,preset){
    let config=read(directory+"/sing-box.json",4194304),output=[];
    if(!config)return [{status:"indeterminate",reason:"generated_config_unavailable"}];
    for(let address in request.device_ips||[]) {
        let host=g.host(address);if(!host)continue;
        for(let domain in [preset.domains[0].value,"trafira-game-test.invalid"]) {
            let test={source_ip:host.address,domain,network:"tcp",protocol:"tls",port:443,inbound:index(host.address,":")>=0?"tproxy6-in":"tproxy-in"};
            let result=matcher.explain(config,test,{},{});
            push(output,{source_ip:host.address,domain,status:result.status,outbound:result.outbound,missing:result.missing});
        }
    }
    return output;
}
function current_action(request,work){
    let digest=hash(transaction.TARGET),source=runtime.read_document(transaction.TARGET,work.directory,"Gaming");
    if(!source.success)return source;
    if(!digest || hash(transaction.TARGET)!=digest)return fail("conflict");
    let catalog=read(CATALOG,1048576);
    if(!catalog || catalog.schema!=1 || type(catalog.presets)!="array")return fail("catalog_unavailable");
    let current={digest,sections:source.document.config,devices:devices(work.directory)};
    if(request.action=="catalog") {
        let owners={};
        for(let section in current.sections)if(section.preset_owner) {
            let item=owners[section.preset_owner]||{owner:section.preset_owner,platform:section.preset_platform||"",edited:false};
            item.edited=item.edited || g.fingerprint(section)!=section.preset_original_digest;owners[item.owner]=item;
        }
        return {success:true,digest,presets:catalog.presets,devices:map(current.devices,(d)=>({name:d.name||"",interface:d.interface,mac:d.mac,ips:d.ips})),
            proxies:map(filter(current.sections,(s)=>s[".type"]=="section" && !s.preset_owner && common.bool_option(s,"enabled",true) && index(["connection","proxy","vpn","outbound"],s.action)>=0),(s)=>({id:s[".name"],label:s.label||s[".name"]})),owners:values(owners)};
    }
    if(request.expected_digest!=digest)return fail("conflict");
    let removal=index(["remove","preview_remove"],request.action)>=0;
    let preset=filter(catalog.presets,(p)=>p.id==request.preset)[0];
    let result=removal?g.remove(request.owner,request.mode,request.confirm,current):g.build(preset,request,current);
    if(!result.valid)return {...fail(result.errors[0]||"invalid_preset"),conflicts:result.conflicts};
    let document={schema:1,name:"Gaming",config:result.config};
    let prepared=runtime.prepare(document,work.directory);
    let applicable=prepared.success && runtime.hooks(document,work.directory).validate(prepared.path);
    if(hash(transaction.TARGET)!=digest)return fail("conflict");
    if(request.action=="preview" || request.action=="preview_remove") {
        return {success:true,digest,applicable,patch:result.patch,changes:format.diff(current.sections,result.config),
            routes:map(result.patch.sections,(s)=>({name:s[".name"],source:s.source_ip_cidr||s.fully_routed_ips,domain:s.domain,domain_suffix:s.domain_suffix,target:s.action=="bypass"?"direct":request.proxy_section})),
            conflicts:result.conflicts,limitations:result.limitations||[],checks:removal?[]:checks(work.directory,request,preset)};
    }
    if(!applicable)return fail("candidate_check_failed");
    return jobs.start_document(document,digest);
}
function action(text){
    let request;try{request=json(text);}catch(e){return fail("invalid_request");}
    if(type(text)!="string" || length(text)>65536 || type(request)!="object")return fail("invalid_request");
    for(let key in request)if(index(["action","preset","device_ips","proxy_section","placement","expected_digest","enable_device","replace_edited","owner","mode","confirm"],key)<0)return fail("invalid_request");
    if(request.action=="status")return jobs.status();
    if(index(["catalog","preview","apply","preview_remove","remove"],request.action)<0)return fail("unsupported_action");
    let lock=locks.acquire("gaming-preset");if(!lock)return fail("busy");
    let work=jobs.new_directory(),result;
    try{result=work?current_action(request,work):fail("storage_unavailable");}catch(e){result=fail("gaming_operation_failed");}
    if(work)jobs.cleanup(work.directory);
    locks.release(lock);return result;
}
print(sprintf("%J\n",ARGV[0]=="action"?action(ARGV[1]):fail("unsupported_action")));
