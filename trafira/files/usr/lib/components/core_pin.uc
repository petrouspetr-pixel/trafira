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
// Pinning an already installed core does not fetch, stage or restart anything.
// Package-backed variants need the exact installed revision, not just the
// version printed by the binary, so later catalog selection matches correctly.
function pin_installed(request,hooks) {
    let current=hooks.current(),env=hooks.environment();
    if(current!=request.expected_current_version || !env || env.variant!=request.expected_current_variant)
        return {success:false,error:"conflict"};
    if(current=="not-installed")return {success:false,error:"not_installed"};
    let version=hooks.installed_version(env),value={version,variant:env.variant};
    if(!valid(value))return {success:false,error:"installed_version_unavailable"};
    if(hooks.current()!=current || hooks.environment().variant!=env.variant)
        return {success:false,error:"conflict"};
    let result=hooks.write(value);
    return result.success?{...result,pin:value}:result;
}
function request_valid(request) {
    if(type(request)!="object" || index(["catalog","install","pin","unpin","status"],request.action)<0)return false;
    let allowed=request.action=="catalog"?["action","refresh"]:request.action=="install"?["action","candidate_id","expected_current_version","pin"]:request.action=="status"?["action","job_id"]:request.action=="pin"?["action","expected_current_version","expected_current_variant"]:["action","expected_current_version"];
    for(let key in request)if(index(allowed,key)<0)return false;
    if(request.action=="catalog")return request.refresh==null || type(request.refresh)=="bool";
    if(request.action=="status")return request.job_id==null || (type(request.job_id)=="string" && match(request.job_id,/^[A-Za-z0-9_-]{1,80}$/));
    if(!safe_version(request.expected_current_version))return false;
    if(request.action=="pin")return index(["stable","tiny","extended","extended-compressed"],request.expected_current_variant)>=0;
    if(request.action=="unpin")return true;
    return type(request.pin)=="bool" && type(request.candidate_id)=="string" &&
        length(request.candidate_id)<=520 && match(request.candidate_id,/^[A-Za-z0-9_.+~-]+$/);
}
return {read,write,request_valid,pin_installed};
