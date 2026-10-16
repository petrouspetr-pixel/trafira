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
    let parent=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira",directory=fs.lstat(parent);
    if(directory && directory.type!="directory")return false;
    if(!directory && !fs.mkdir(parent,493))return false;
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
function stop_calculator(dir){
    let saved=read(dir+"/calculator.json",1024),alive=saved?identity(saved.pid):null;
    if(alive && alive.ticks==saved.ticks)system("kill -KILL "+alive.pid+" 2>/dev/null");
    fs.unlink(dir+"/calculator.json");
}
function cleanup(id){
    if(!valid(id))return;
    stop_calculator(ROOT+"/"+id);
    require("diagnostics.route_decode_cache").cleanup(ROOT+"/"+id);
    require("diagnostics.route_memory").cleanup(ROOT+"/"+id);
    for(let name in ["request.json","state.json","result.json","state.json.stage","result.json.stage","calculator.json.stage","exit.status","dns-answer"])fs.unlink(ROOT+"/"+id+"/"+name);
    fs.rmdir(ROOT+"/"+id);
}
function status(id){
    if(!valid(id))return fail("invalid_job");
    let state=read(ROOT+"/"+id+"/state.json",1048576);
    if(!state || state.job_id!=id)return fail("invalid_job");
    if(state.running) {
        let age=clock()[0]-state.started_at,alive=state.worker?identity(state.worker.pid):null;
        if(age>130)return fail("worker_timeout");
        if((state.worker || age>=10) && (!alive || alive.ticks!=state.worker.ticks || alive.state=="Z"))return fail("worker_interrupted");
    }
    // Never export request files, process identities, filesystem paths or codec stderr.
    return {success:state.success!==false,running:state.running===true,job_id:id,progress:state.progress,report:state.report,error:state.error};
}
function start(raw){
    if(!analysis.validate(raw))return fail("invalid_request");
    if(!ensure())return fail("storage_unavailable");
    let guard=lock();if(!guard)return fail("busy");
    let current=read(ROOT+"/active.json",1024);
    if(current && status(current.id).running){guard.close();return fail("busy");}
    if(current && valid(current.id)){stop_calculator(ROOT+"/"+current.id);require("diagnostics.route_decode_cache").cleanup(ROOT+"/"+current.id);}
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
    if(!write(dir+"/calculator.json",identity()))return false;
    // Registration comes first: a new owner either sees us or we observe its takeover.
    let owner=state.worker?identity(state.worker.pid):null,current=read(ROOT+"/active.json",1024);
    if(!owner || owner.ticks!=state.worker.ticks || owner.state=="Z" || !current || current.id!=id){fs.unlink(dir+"/calculator.json");return false;}
    let report=analysis.explain(request.raw,{background:true,workspace:dir,progress:(progress)=>{
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
    let watcher="setsid "+join(" ",map(["ucode","-L",LIB,LIB+"/diagnostics/route_memory.uc","watch",dir,state.worker.pid,state.worker.ticks],quote))+" </dev/null >/dev/null 2>&1 &";
    let memory=require("diagnostics.route_memory"),monitor=null;
    if(system(watcher)==0)for(let n=0;n<40 && !monitor;n++) {
        let saved=read(dir+"/memory-monitor.json",1024),alive=saved?identity(saved.pid):null;
        if(alive && alive.ticks==saved.ticks && alive.state!="Z")monitor=alive;
        else system("sleep 0.05");
    }
    if(!monitor){let failed={success:false,running:false,job_id:id,error:"worker_interrupted"};write(dir+"/state.json",failed);memory.cleanup(dir);guard.close();return failed;}
    // The supervisor remains responsive while the calculator runs: loss of the
    // mandatory monitor aborts the calculator and its descendants immediately.
    let command="(ulimit -Sv 131072; "+join(" ",map(["ucode","-L",LIB,LIB+"/diagnostics/route_job.uc","calculate",id],quote))+" >/dev/null 2>&1; printf '%s' $? > "+quote(dir+"/exit.status")+") </dev/null >/dev/null 2>&1 & echo $!";
    let pipe=fs.popen(command,"re"),pid=pipe?trim(pipe.read(64)||""):"",started=clock(true),launcher=match(pid,/^[1-9][0-9]*$/)?identity(pid):null;
    if(pipe)pipe.close();
    let code=-1;
    for(let n=0;launcher && n<2500;n++) {
        let alive=identity(monitor.pid);
        if(!alive || alive.ticks!=monitor.ticks || alive.state=="Z") {
            // A memory stop intentionally ends the monitor after writing error.
            memory.stop(memory.tree(launcher,{}));
            break;
        }
        let exited=fs.readfile(dir+"/exit.status");
        if(exited!=null){code=int(exited);break;}
        if(clock(true)[0]-started[0]>=125){code=-9;memory.stop(memory.tree(launcher,{}));break;}
        system("sleep 0.05");
    }
    let ended=clock(true),report=code==0?read(dir+"/result.json",1048576):null;
    fs.unlink(dir+"/exit.status");
    let result=report?{success:true,running:false,job_id:id,report}:{success:false,running:false,job_id:id,error:fs.readfile(dir+"/memory.error")=="resource_limit"?"resource_limit":code==-9 && ended[0]-started[0]>=124?"worker_timeout":"worker_interrupted"};
    stop_calculator(dir);
    require("diagnostics.route_decode_cache").cleanup(dir);
    require("diagnostics.route_memory").cleanup(dir);
    write(dir+"/state.json",result);fs.unlink(dir+"/request.json");fs.unlink(dir+"/result.json");guard.close();return result;
}
let mode=ARGV[0];
if(mode=="calculate")exit(calculate(ARGV[1])?0:1);
print(sprintf("%J\n",mode=="start"?start(ARGV[1]):mode=="status"?status(ARGV[1]):mode=="supervisor"?supervisor(ARGV[1]):fail("invalid_command")));
