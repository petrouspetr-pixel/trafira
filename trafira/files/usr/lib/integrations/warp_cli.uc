// SPDX-License-Identifier: GPL-3.0-only
// WARP mutations share Trafira's lock before acquiring the addon's private lock.
let fs=require("fs"),locks=require("service.operation_lock");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ADDON=getenv("TRAFIRA_WARP_LIB")||"/usr/lib/trafira-warp";
function fail(error){return {success:false,error};}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function modules() {
    if(!fs.stat(ADDON+"/warp/job.uc"))return null;
    return {state:require("warp.state"),job:require("warp.job")};
}
function worker(id) {
    let m=modules();if(!m || !m.job.valid_id(id))return fail("invalid_job");
    let lock=null;
    for(let n=0;n<5 && !lock;n++){lock=locks.acquire("warp-worker",false);if(!lock)system("sleep 1");}
    if(!lock)return fail("busy");
    let result;
    try {
        let request=m.state.load(m.state.RUNTIME+"/request.json"),current=m.state.load(m.state.RUNTIME+"/job.json");
        if(!request || request.job_id!=id || !current || current.job_id!=id || !current.running)result=fail("invalid_job");
        else {
            let runtime=require("warp.runtime");
            result=m.job.execute(request.request,runtime.hooks(),id);
        }
    }catch(e){result=fail("worker_failed");}
    let current=m.state.load(m.state.RUNTIME+"/job.json");
    if(current?.job_id==id)m.state.save(m.state.RUNTIME+"/job.json",{...m.state.public_status(result),job_id:id,running:false});
    locks.release(lock);return result;
}
function action(text) {
    if(type(text)!="string" || length(text)>16384)return fail("invalid_request");
    let request;try {request=json(text);}catch(e){return fail("invalid_request");}
    let m=modules();if(!m)return fail("component_not_installed");
    if(!m.job.valid_request(request))return fail("invalid_request");
    if(request.action=="job_status")return m.job.status();
    if(request.action=="cancel")return m.job.cancel(request.job_id);
    if(request.action=="status") {
        try {return require("warp.runtime").status();}catch(e){return fail("component_unavailable");}
    }
    let lock=locks.acquire("warp-start",false);if(!lock)return fail("busy");
    let result;
    try {
        if(m.job.status().running)result=fail("busy");
        else {
            let id=sprintf("w-%x-%x",clock()[0],clock()[1]),root=m.state.RUNTIME;
            if(!m.state.save(root+"/request.json",{job_id:id,request}) || !m.state.save(root+"/job.json",{job_id:id,running:true,started_at:clock()[0]}))result=fail("storage_unavailable");
            else {
                let command="setsid "+join(" ",map(["ucode","-L",LIB,"-L",ADDON,LIB+"/integrations/warp_cli.uc","worker",id],quote))+" </dev/null >/dev/null 2>&1 & echo $!";
                let pipe=fs.popen(command,"re"),pid=pipe?trim(pipe.read(64)||""):"";
                if(!pipe || pipe.close()!=0 || !match(pid,/^[1-9][0-9]*$/)) {
                    result=fail("launch_failed");m.state.save(root+"/job.json",{...result,job_id:id,running:false});
                }else result={success:true,running:true,job_id:id};
            }
        }
    }catch(e){result=fail("operation_failed");}
    locks.release(lock);return result;
}
print(sprintf("%J\n",ARGV[0]=="worker"?worker(ARGV[1]):ARGV[0]=="action"?action(ARGV[1]):fail("invalid_request")));
