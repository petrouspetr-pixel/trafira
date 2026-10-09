// SPDX-License-Identifier: GPL-3.0-only
// Internal package coordinator only; never exported over RPC.
let fs=require("fs"),locks=require("service.operation_lock");
function permitted(path) {
    if(type(path)!="string" || !match(path,/^\/(tmp|etc\/trafira)\/[A-Za-z0-9_./-]+\/state.json$/) || index(path,"..")>=0)return false;
    let parent=fs.lstat(substr(path,0,rindex(path,"/"))),info=fs.lstat(path);
    return parent && parent.type=="directory" && (parent.mode&63)==0 && (!info || (info.type=="file" && (info.mode&63)==0));
}
function execute(action,path) {
    let owner;try {owner=json(fs.readfile((getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/operation-owner.json"));}catch(e){}
    if(!locks.is_live_ancestor(owner) || !permitted(path))return {success:false,error:"permission_denied"};
    let state=require("warp.state"),transport=require("warp.transport"),job=require("warp.job");
    if(action=="snapshot") {
        let status=job.status();if(status.running || status.recovery_pending)return {success:false,error:"busy"};
        let saved={transport:transport.snapshot(),files:{}};
        for(let name in ["account.json","registration.json","transport.json","awg.conf"]){
            let file=state.DIRECTORY+"/"+name,info=fs.lstat(file);
            if(info && (info.type!="file" || info.size>2097152))return {success:false,error:"invalid_state"};
            saved.files[name]=info?fs.readfile(file):null;
        }
        let text=sprintf("%J",saved),f=fs.open(path,"we",384);if(!f)return {success:false,error:"storage_unavailable"};
        let ok=f.write(text)==length(text);f.close();return {success:ok && fs.readfile(path)==text};
    }
    let saved;try {saved=json(fs.readfile(path));}catch(e){}
    if(!saved?.transport || type(saved.files)!="object")return {success:false,error:"invalid_state"};
    if(action=="resume") {
        if(!saved.transport.running)return {success:system("/etc/init.d/trafira-warp stop >/dev/null 2>&1")==0};
        return require("warp.runtime").activate({...saved.transport.config,enabled:true},"package-resume");
    }
    if(action=="restore") {
        for(let name in ["account.json","registration.json"])
            if(saved.files[name]!=null && !state.save_text(state.DIRECTORY+"/"+name,saved.files[name]))return {success:false,error:"restore_failed"};
        return {success:transport.restore(saved.transport,"package-restore")};
    }
    if(action=="remove") {
        let config=state.load(state.DIRECTORY+"/transport.json");
        if(config && length(require("integrations.warp_model").references({config:require("integrations.warp_attach").references()},config.interface)))return {success:false,error:"references_exist"};
        return {success:transport.restore({config:null,running:false},"package-remove")};
    }
    return {success:false,error:"invalid_request"};
}
return {execute};
