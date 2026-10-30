let fs=require("fs"),sources=require("components.core_sources"),catalog=require("components.core_catalog");
let pin=require("components.core_pin"),locks=require("service.operation_lock");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
function failure(error){return {success:false,error};}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function updater(args) {
    let command=join(" ",map(["ucode","-L",LIB,LIB+"/components/updates.uc",...args],quote));
    let p=fs.popen(command+" 2>/dev/null","re");if(!p)return failure("worker_unavailable");
    let text=p.read(65537),status=p.close();
    if(text==null || length(text)>65536)return failure("invalid_worker_response");
    try {
        let value=json(text);
        if(type(value)=="object")return value;
    }catch(e){}
    return failure(status==0?"invalid_worker_response":"worker_failed");
}
function status(request) {
    let result=request.job_id?updater(["component-action-status",request.job_id]):updater(["component-version-status"]);
    return {success:result.success!==false,running:result.running===true,job_id:result.job_id||request.job_id||"",
        error:result.error||(!result.success?"version_action_failed":""),restored:result.restored===true,rollback_error:result.rollback_error||""};
}
function catalog_snapshot() {
    let lock=locks.acquire_read();
    if(!lock)return null;
    let result;
    try {result={environment:sources.environment(),current_version:sources.current_version(),pin:pin.read()};}
    catch(e){result=null;}
    locks.release(lock);
    return result;
}
function load_catalog(request) {
    let before=catalog_snapshot();
    if(!before)return failure("busy");
    // Network and package metadata downloads must not block configuration writes.
    let result=catalog.load(before.environment,request.refresh,sources.fetch);
    let after=catalog_snapshot();
    if(!after)return failure("busy");
    if(before.current_version!=after.current_version || sprintf("%J",before.environment)!=sprintf("%J",after.environment))
        return failure("conflict");
    return {...result,current_version:after.current_version,current_variant:after.environment.variant,pin:after.pin};
}
function dispatch(request) {
    if(request.action=="catalog")return load_catalog(request);
    if(request.action=="status")return status(request);
    if(request.expected_current_version!=sources.current_version())return failure("conflict");
    if(request.action=="pin")return pin.pin_installed(request,{current:sources.current_version,environment:sources.environment,installed_version:sources.installed_version,write:pin.write});
    if(request.action=="unpin") {
        let result=pin.write(null);
        return result.success?{...result,pin:null}:result;
    }
    let result=updater(["component-version-async",sprintf("%J",request)]);
    return result.success?{success:true,running:true,job_id:result.job_id}:failure(result.error||"launch_failed");
}
function action(text) {
    if(type(text)!="string" || length(text)>8192)return failure("invalid_request");
    let request;
    try {request=json(text);}catch(e){return failure("invalid_request");}
    if(!pin.request_valid(request))return failure("invalid_request");
    if(request.action=="status")return status(request);
    if(request.action=="catalog") {
        try {return load_catalog(request);}catch(e){return failure("version_action_failed");}
    }
    let lock=locks.acquire("core-version-action");if(!lock)return failure("busy");
    let result;
    try {result=dispatch(request);}catch(e){result=failure("version_action_failed");}
    locks.release(lock);return result;
}
print(sprintf("%J\n",ARGV[0]=="action"?action(ARGV[1]):failure("invalid_request")));
