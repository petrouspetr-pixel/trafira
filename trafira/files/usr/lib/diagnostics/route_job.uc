// Read-only analysis jobs: private request/state files, one bounded supervisor.
let fs=require("fs"),analysis=require("diagnostics.route_analysis"),identity=require("service.operation_lock").identity;
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ROOT=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/route-analysis";
function fail(error){return {success:false,running:false,error};}
function valid(id){return type(id)=="string" && match(id,/^r-[a-f0-9-]{1,60}$/);}
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function read(path,limit){
    let info=fs.lstat(path);if(!info || info.type!="file" || info.size>limit)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let raw=file.read(limit+1);file.close();
    if(length(raw||"")>limit)return null;
    try{return json(raw);}catch(e){return null;}
}
function write(path,value){
    let raw=sprintf("%J",value),temporary=path+".stage",info=fs.lstat(temporary);
    if(length(raw)>1048576 || (info && (info.type!="file" || !fs.unlink(temporary))))return false;
    let file=fs.open(temporary,"wex",384);if(!file)return false;
    let ok=file.write(raw)==length(raw);file.close();
    if(ok)ok=fs.rename(temporary,path);fs.unlink(temporary);return !!ok;
}
function ensure(){
    let info=fs.lstat(ROOT);if(info && info.type!="directory")return false;
    if(!info && !fs.mkdir(ROOT,448))return false;
    return fs.chmod(ROOT,448);
}
function lock(){
    if(!ensure())return null;
    let info=fs.lstat(ROOT+"/lock");if(info && info.type!="file")return null;
    let file=fs.open(ROOT+"/lock","ae",384);
    if(!file)return null;
    if(!file.lock("xn")){file.close();return null;}
    return file;
}
function cleanup(id){
    if(!valid(id))return;
    for(let name in ["request.json","state.json","result.json","state.json.stage","result.json.stage"])fs.unlink(ROOT+"/"+id+"/"+name);
    fs.rmdir(ROOT+"/"+id);
}
function status(id){
    if(!valid(id))return fail("invalid_job");
    let state=read(ROOT+"/"+id+"/state.json",1048576);
    if(!state || state.job_id!=id)return fail("invalid_job");
    if(state.running) {
        let age=clock()[0]-state.started_at,alive=state.worker?identity(state.worker.pid):null;
        if(age>130)return fail("worker_timeout");
        if(age>=10 && (!alive || alive.ticks!=state.worker.ticks || alive.state=="Z"))return fail("worker_interrupted");
    }
    // Never export request files, process identities, filesystem paths or codec stderr.
    return {success:state.success!==false,running:state.running===true,job_id:id,progress:state.progress,report:state.report,error:state.error};
}
function start(raw){
    if(!analysis.validate(raw))return fail("invalid_request");
    let guard=lock();if(!guard)return fail("busy");
    let current=read(ROOT+"/active.json",1024);
    if(current && status(current.id).running){guard.close();return fail("busy");}
    let entries=[];
    for(let name in fs.lsdir(ROOT)||[])if(valid(name)) {
        let info=fs.lstat(ROOT+"/"+name);
        if(info && info.type=="directory" && clock()[0]-info.mtime>600)cleanup(name);
        else if(info && info.type=="directory")push(entries,{id:name,mtime:info.mtime});
    }
    entries=sort(entries,(a,b)=>a.mtime-b.mtime);
    while(length(entries)>=8){let old=shift(entries);if(status(old.id).running){guard.close();return fail("busy");}cleanup(old.id);}
    let now=clock(),id=sprintf("r-%x-%x",now[0],now[1]),dir=ROOT+"/"+id;
    if(!fs.mkdir(dir,448) || !write(dir+"/request.json",{raw}) || !write(dir+"/state.json",{success:true,running:true,job_id:id,started_at:now[0],progress:{completed:0,total:0,phase:"preparing"}}) || !write(ROOT+"/active.json",{id})) {
        cleanup(id);guard.close();return fail("storage_unavailable");
    }
    let command="setsid "+join(" ",map(["ucode","-L",LIB,LIB+"/diagnostics/route_job.uc","supervisor",id],quote))+" </dev/null >/dev/null 2>&1 & echo $!";
    let pipe=fs.popen(command,"re"),pid=pipe?trim(pipe.read(64)||""):"",ok=pipe && pipe.close()==0 && match(pid,/^[1-9][0-9]*$/);
    guard.close();
    if(!ok){write(dir+"/state.json",{success:false,running:false,job_id:id,error:"worker_interrupted"});return fail("worker_interrupted");}
    return {success:true,running:true,job_id:id,progress:{completed:0,total:0,phase:"preparing"}};
}
function calculate(id){
    if(!valid(id))return false;
    let dir=ROOT+"/"+id,request=read(dir+"/request.json",16384),state=read(dir+"/state.json",4096);
    if(!request || !state || !state.running || state.job_id!=id || !analysis.validate(request.raw))return false;
    let report=analysis.explain(request.raw,{background:true,progress:(progress)=>{
        state.progress=progress;write(dir+"/state.json",state);
    }});
    return write(dir+"/result.json",report);
}
function supervisor(id){
    if(!valid(id))return fail("invalid_job");
    let guard=null;
    for(let n=0;n<30 && !guard;n++){guard=lock();if(!guard)system("sleep 0.1");}
    if(!guard)return fail("busy");
    let dir=ROOT+"/"+id,state=read(dir+"/state.json",4096);
    if(!state || !state.running || state.job_id!=id){guard.close();return fail("invalid_job");}
    state.worker=identity();write(dir+"/state.json",state);
    let command="exec "+join(" ",map(["ucode","-L",LIB,LIB+"/diagnostics/route_job.uc","calculate",id],quote))+" >/dev/null 2>&1";
    let code=system(command,125000),report=code==0?read(dir+"/result.json",1048576):null;
    let result=report?{success:true,running:false,job_id:id,report}:{success:false,running:false,job_id:id,error:code==-9?"worker_timeout":"worker_interrupted"};
    write(dir+"/state.json",result);fs.unlink(dir+"/request.json");fs.unlink(dir+"/result.json");guard.close();return result;
}
let mode=ARGV[0];
if(mode=="calculate")exit(calculate(ARGV[1])?0:1);
print(sprintf("%J\n",mode=="start"?start(ARGV[1]):mode=="status"?status(ARGV[1]):mode=="supervisor"?supervisor(ARGV[1]):fail("invalid_command")));
