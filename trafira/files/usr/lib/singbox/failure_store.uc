let fs=require("fs"),hash=require("singbox.provenance").hash_file,policy=require("singbox.failure_policy");
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
const STATE=ROOT+"/failure-policy.json";
const LIMIT=4194304;
function read(path) {
    let stat=fs.lstat(path);
    if(!stat || stat.type!="file" || stat.size>LIMIT)return null;
    try {return json(fs.readfile(path));}catch(e){return null;}
}
function write(path,value) {
    let text=sprintf("%J\n",value);if(length(text)>LIMIT)return false;
    let stat=fs.lstat(path);if(stat && stat.type!="file")return false;
    let temporary=path+sprintf(".%x-%x.stage",clock()[0],clock()[1]);
    let f=fs.open(temporary,"wex",384);if(!f)return false;
    let ok=f.write(text)==length(text);f.close();
    if(!ok || fs.readfile(temporary)!=text) {fs.unlink(temporary);return false;}
    if(!fs.rename(temporary,path)) {fs.unlink(temporary);return false;}
    return true;
}
function descriptors(sections) {
    let result=[];
    for(let section in sections||[]) {
        let p=policy.from_section(section);if(p.mode=="legacy")continue;
        let item={".name":section[".name"],action:section.action};
        for(let key in ["failure_policy","failure_reserve_section","failure_threshold","recovery_threshold","failure_hold_seconds"])
            if(section[key]!=null)item[key]=section[key];
        push(result,item);
    }
    return result;
}
function save_base(path,config,sections) {
    let selected=descriptors(sections),digest=hash(path);
    if(!digest)return false;
    if(!length(selected)) {
        if(fs.lstat(path+".failure-policy.json"))return fs.unlink(path+".failure-policy.json");
        return true;
    }
    // Generation changes even if an ordinary reload produced identical JSON:
    // fresh initialization must not inherit a previous worker health decision.
    let generation=digest+sprintf("-%x-%x",clock()[0],clock()[1]);
    return write(path+".failure-policy.json",{schema:1,generation,initial_digest:digest,config,sections:selected});
}
function load(path) {
    let base=read(path+".failure-policy.json");
    if(!base || base.schema!=1 || type(base.generation)!="string" || type(base.config)!="object" || type(base.sections)!="array")return null;
    let state=read(STATE),digest=hash(path);
    if(state && state.generation==base.generation && state.applied_digest==digest) return {...base,states:state.states||{},applied_digest:digest};
    return digest==base.initial_digest?{...base,states:{},applied_digest:digest}:null;
}
function publish(generation,path,states) {
    let stat=fs.lstat(ROOT);
    if(stat && stat.type!="directory")return false;
    if(!stat && !fs.mkdir(ROOT,493))return false;
    let digest=hash(path);if(!digest)return false;
    return write(STATE,{schema:1,generation,applied_digest:digest,states});
}
return {read,write,descriptors,save_base,load,publish};
