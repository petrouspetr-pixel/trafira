let uci=require("core.uci"),locks=require("service.operation_lock");
const VERSION="trafira.settings.sing_box_pinned_version",VARIANT="trafira.settings.sing_box_pinned_variant";
function safe_version(value) {return type(value)=="string" && match(value,/^[A-Za-z0-9_.+-]{1,128}$/);}
function valid(value) {
    return value==null || (type(value)=="object" && safe_version(value.version) && index(["stable","tiny","extended","extended-compressed"],value.variant)>=0);
}
function read() {
    let version=uci.get(VERSION)||"",variant=uci.get(VARIANT)||"";
    return version || variant?{version,variant}:null;
}
function set_value(path,value) {
    if(value)return uci.set(path,value);
    return !uci.exists(path) || uci.delete(path);
}
function save(value) {
    return set_value(VERSION,value?value.version:"") && set_value(VARIANT,value?value.variant:"") && uci.commit("trafira");
}
function write(value) {
    if(!valid(value))return {success:false,error:"invalid_pin"};
    let lock=locks.acquire("core-pin");if(!lock)return {success:false,error:"busy"};
    let old=read(),result;
    try {
        if(save(value))result={success:true};
        else {
            let restored=save(old);
            result={success:false,error:"pin_write_failed",restored};
            if(!restored)result.rollback_error="pin_restore_failed";
        }
    }catch(e){result={success:false,error:"pin_write_failed",rollback_error:"pin_restore_failed"};}
    locks.release(lock);return result;
}
function request_valid(request) {
    if(type(request)!="object" || index(["catalog","install","unpin","status"],request.action)<0)return false;
    let allowed=request.action=="catalog"?["action","refresh"]:request.action=="install"?["action","candidate_id","expected_current_version","pin"]:request.action=="status"?["action","job_id"]:["action","expected_current_version"];
    for(let key in request)if(index(allowed,key)<0)return false;
    if(request.action=="catalog")return request.refresh==null || type(request.refresh)=="bool";
    if(request.action=="status")return request.job_id==null || (type(request.job_id)=="string" && match(request.job_id,/^[A-Za-z0-9_-]{1,80}$/));
    if(!safe_version(request.expected_current_version))return false;
    if(request.action=="unpin")return true;
    return type(request.pin)=="bool" && type(request.candidate_id)=="string" &&
        length(request.candidate_id)<=520 && match(request.candidate_id,/^[A-Za-z0-9_.+~-]+$/);
}
return {read,write,request_valid};
