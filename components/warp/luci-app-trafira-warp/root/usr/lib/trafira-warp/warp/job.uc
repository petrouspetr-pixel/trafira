// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state");
const ACTIVE=state.DIRECTORY+"/active.json",BACKUP=state.DIRECTORY+"/rollback.json";
const CURRENT=state.RUNTIME+"/job.json",CANCEL=state.RUNTIME+"/cancel.json";
const ACTIONS=["status","register","enable","disable","reconnect","preview_attach","attach","preview_detach","detach","unregister","scan_start","scan_apply","test_start","cancel","job_status"];
function failure(error){return {success:false,error};}
function valid_id(value){return type(value)=="string" && match(value,/^[a-z0-9-]{1,80}$/);}
function valid_request(request) {
    if(type(request)!="object" || index(ACTIONS,request.action)<0 || length(sprintf("%J",request))>16384)return false;
    let fields={status:[],job_status:["job_id"],cancel:["job_id"],register:[],enable:[],disable:[],reconnect:[],unregister:[],
        preview_attach:[],attach:["expected_digest","preview_id"],preview_detach:[],detach:["expected_digest","preview_id"],
        scan_start:["mode"],scan_apply:["candidate_id"],test_start:["duration","services"]};
    for(let key in request)if(key!="action" && index(fields[request.action],key)<0)return false;
    if(request.action=="scan_start" && index(["quick","full"],request.mode)<0)return false;
    if(request.action=="test_start") {
        if(index([15,30,45,60],request.duration)<0 || type(request.services)!="array" || !length(request.services) || length(request.services)>5)return false;
        for(let id in request.services)if(index(["google","chatgpt","gemini","grok","cloudflare"],id)<0)return false;
    }
    if(index(["attach","detach"],request.action)>=0 && (type(request.expected_digest)!="string" || !match(request.expected_digest,/^[a-f0-9]{64}$/) || !valid_id(request.preview_id)))return false;
    if(request.action=="scan_apply" && !valid_id(request.candidate_id))return false;
    if(request.action=="cancel" && !valid_id(request.job_id))return false;
    if(request.job_id!=null && !valid_id(request.job_id))return false;
    return true;
}
function identity(pid) {
    if(pid!=null && !match(""+pid,/^[1-9][0-9]*$/))return null;
    let raw=fs.readfile("/proc/"+(pid||"self")+"/stat");if(!raw)return null;
    let end=rindex(raw,")"),fields=split(trim(substr(raw,end+1)),/\s+/);
    return {pid:substr(raw,0,index(raw," ")),ticks:fields[19],state:fields[0],group:fields[2],session:fields[3]};
}
function live(owner) {
    let actual=owner?identity(owner.pid):null;
    return actual && actual.ticks==owner.ticks && actual.state!="Z";
}
function status() {
    let value=state.load(CURRENT)||{running:false},journal=fs.lstat(ACTIVE);
    if(value.running && ((value.worker && !live(value.worker)) || (!value.worker && clock()[0]-(value.started_at||0)>10)))
        value={...value,success:false,running:false,error:"worker_interrupted"};
    return state.public_status({...value,recovery_pending:!!journal});
}
function cancel(id) {
    let current=state.load(CURRENT);
    if(!valid_id(id) || !current || current.job_id!=id || !current.running)return failure("job_not_running");
    return state.save(CANCEL,{job_id:id})?{success:true,running:true,job_id:id}:failure("storage_unavailable");
}
function cancelled(id){return state.load(CANCEL)?.job_id==id;}
function recover(hooks) {
    if(!fs.lstat(ACTIVE))return {success:true,restored:false};
    let journal=state.load(ACTIVE),backup=state.load(BACKUP);
    if(!journal || journal.schema!=1 || !backup || backup.job_id!=journal.job_id)return {...failure("recovery_error"),rollback_error:true};
    let restored=false;try {restored=hooks.restore(backup.snapshot)===true;}catch(e){}
    if(!restored)return {...failure("recovery_error"),rollback_error:true};
    if(!state.remove(ACTIVE))return {...failure("recovery_error"),rollback_error:true};
    state.remove(BACKUP);return {success:true,restored:true};
}
function enough_space(snapshot) {
    let p=fs.popen("df -P -k '"+replace(state.DIRECTORY,/'/g,"'\\''")+"' 2>/dev/null","re");
    if(!p)return false;
    let text=p.read(8193),code=p.close();if(code!=0 || length(text||"")>8192)return false;
    let lines=filter(split(text||"","\n"),(line)=>trim(line)!="");
    let fields=split(trim(lines[length(lines)-1]||""),/\s+/);
    return length(fields)>=6 && match(fields[3],/^[0-9]+$/) && int(fields[3])*1024>=2*length(sprintf("%J",snapshot))+1048576;
}
function execute(request,hooks,id) {
    if(!valid_request(request))return failure("invalid_request");
    id=id||sprintf("w-%x-%x",clock()[0],clock()[1]);
    if(!valid_id(id) || !state.ensure(state.RUNTIME) || !state.ensure(state.DIRECTORY))return failure("storage_unavailable");
    let info=fs.lstat(state.RUNTIME+"/operation.lock");if(info && info.type!="file")return failure("storage_unavailable");
    let lock=fs.open(state.RUNTIME+"/operation.lock","ae",384);
    if(!lock || !lock.lock("xn")){if(lock)lock.close();return failure("busy");}
    let result;
    try {
        result=recover(hooks);
        if(result.success) {
            let snapshot=hooks.snapshot();
            if(type(snapshot)!="object" || !enough_space(snapshot) || !state.save(BACKUP,{schema:1,job_id:id,snapshot}) ||
                !state.save(ACTIVE,{schema:1,job_id:id,worker:identity(),stage:"prepared",expected_digest:request.expected_digest}))result=failure("storage_unavailable");
            else {
                let current={job_id:id,running:true,worker:identity(),started_at:clock()[0],stage:"running"};
                if(!state.save(CURRENT,current))result=failure("storage_unavailable");
                else try {result=cancelled(id)?failure("cancelled"):hooks.perform(request,id);}catch(e){result=failure("operation_failed");}
                if(type(result)!="object")result=failure("operation_failed");
                if(result.success) {
                    if(!state.remove(ACTIVE))result=failure("storage_unavailable");
                    else state.remove(BACKUP);
                }
                if(!result.success) {
                    let recovery=recover(hooks);result={...result,restored:recovery.restored===true,rollback_error:recovery.rollback_error===true};
                }
            }
        }
    }catch(e){result={...failure("operation_failed"),recovery_pending:!!fs.lstat(ACTIVE)};}
    state.save(CURRENT,{...state.public_status(result),job_id:id,running:false,completed_at:clock()[0]});
    lock.close();return {...state.public_status(result),job_id:id};
}
return {valid_request,valid_id,identity,live,status,cancel,cancelled,recover,execute};
