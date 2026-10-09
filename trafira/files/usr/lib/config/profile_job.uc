let fs=require("fs"),locks=require("service.operation_lock"),transaction=require("service.config_transaction");
let runtime=require("config.profile_runtime"),profiles=require("config.profiles"),hash=require("singbox.provenance").hash_file;
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ROOT=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/profile-work";
const STATE=ROOT+"/job.json";
function fail(error){return {success:false,error};}
function valid(id){return type(id)=="string" && match(id,/^j-[a-f0-9-]{1,60}$/);}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function read(path,limit){
    let stat=fs.lstat(path);if(!stat || stat.type!="file" || stat.size>limit)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let text=file.read(limit+1);file.close();
    if(length(text||"")>limit)return null;
    try{return json(text);}catch(e){return null;}
}
function write(path,data){
    let text=sprintf("%J",data),temporary=path+".stage";
    let old=fs.lstat(temporary);if(old && (old.type!="file" || !fs.unlink(temporary)))return false;
    let file=fs.open(temporary,"wex",384);if(!file)return false;
    let ok=file.write(text)==length(text);file.close();
    return ok && fs.readfile(temporary)==text && fs.rename(temporary,path);
}
function ensure(){
    let info=fs.lstat(ROOT);if(info && info.type!="directory")return false;
    if(!info && !fs.mkdir(ROOT,448))return false;
    return fs.chmod(ROOT,448);
}
function remove_tree(path){
    let stat=fs.lstat(path);if(!stat)return;
    if(stat.type=="directory") {
        for(let name in fs.lsdir(path)||[])remove_tree(path+"/"+name);
        fs.rmdir(path);
    } else fs.unlink(path);
}
function cleanup(directory){
    if(substr(directory,0,length(ROOT)+1)!=ROOT+"/" || !valid(substr(directory,length(ROOT)+1)))return;
    remove_tree(directory);
}
function new_directory(){
    if(!ensure())return null;
    let count=0;
    for(let name in fs.lsdir(ROOT)||[])if(valid(name)) {
        let info=fs.lstat(ROOT+"/"+name);
        if(info && clock()[0]-info.mtime>3600)cleanup(ROOT+"/"+name);
        else count++;
    }
    if(count>=8)return null;
    let id=sprintf("j-%x-%x",clock()[0],clock()[1]),directory=ROOT+"/"+id;
    return fs.mkdir(directory,448)?{id,directory}:null;
}
function status(){
    let state=read(STATE,4096),pending=transaction.status();
    if(!state)return {success:true,running:false,recovery_pending:pending.recovery_pending||false};
    if(state.running) {
        let alive=state.worker?locks.identity(state.worker.pid):null;
        let starting=!state.worker && clock()[0]-state.started_at<10;
        if(!starting && (!alive || alive.ticks!=state.worker.ticks || alive.state=="Z"))
            return {success:false,running:false,job_id:state.job_id,error:"worker_interrupted",recovery_pending:pending.recovery_pending||false};
    }
    // Only this whitelist reaches the browser; requests and profile data stay private.
    return {success:state.success!==false,running:state.running===true,job_id:state.job_id,error:state.error,restored:state.restored||false,rollback_error:state.rollback_error,recovery_pending:pending.recovery_pending||false};
}
function worker(id){
    if(!valid(id))return fail("invalid_job");
    let lock=null;
    for(let n=0;n<5 && !lock;n++) {
        lock=locks.acquire("profile-worker",false);
        if(!lock)system("sleep 1");
    }
    if(!lock)return fail("busy");
    let state=read(STATE,4096),directory=ROOT+"/"+id,result;
    try {
        let request=read(directory+"/request.json",2097152);
        if(!state || state.job_id!=id || !state.running || !request)result=fail("invalid_job");
        else {
            state.worker=locks.identity();
            if(!write(STATE,state))result=fail("storage_unavailable");
            else if(request.recover)result=transaction.recover(runtime.hooks(null,directory));
            else {
                let prepared=runtime.prepare(request.document,directory);
                result=prepared.success?transaction.apply(prepared.path,request.digest,"profile",runtime.hooks(request.document,directory)):prepared;
            }
        }
    }catch(e){result=fail("profile_operation_failed");}
    if(state && state.job_id==id)write(STATE,{...result,job_id:id,running:false});
    cleanup(directory);locks.release(lock);return result;
}
function start(request,restore){
    if(status().running)return fail("busy");
    if(type(request.digest)!="string" || !match(request.digest,/^[a-f0-9]{64}$/) || hash(transaction.TARGET)!=request.digest)return fail("conflict");
    let work=new_directory();if(!work)return fail("storage_unavailable");
    let pending=transaction.status(),recovery=restore && pending.recovery_pending;
    let source=recovery?{success:true}:restore?runtime.read_document(transaction.previous_path(),work.directory,"Previous"):profiles.export_profile(request.id);
    if(!source.success){cleanup(work.directory);return source;}
    if(!write(work.directory+"/request.json",{document:source.document,digest:request.digest,recover:recovery||false}) || !write(STATE,{running:true,job_id:work.id,started_at:clock()[0]})) {
        cleanup(work.directory);return fail("storage_unavailable");
    }
    let command="setsid "+join(" ",map(["ucode","-L",LIB,LIB+"/config/profile_cli.uc","worker",work.id],quote))+" </dev/null >/dev/null 2>&1 & echo $!";
    let pipe=fs.popen(command,"re"),pid=pipe?trim(pipe.read(64)||""):"";
    let launched=pipe && pipe.close()==0 && match(pid,/^[1-9][0-9]*$/);
    if(!launched){write(STATE,{running:false,success:false,error:"launch_failed",job_id:work.id});cleanup(work.directory);return fail("launch_failed");}
    return {success:true,running:true,job_id:work.id};
}
return {start,worker,status,new_directory,cleanup};
