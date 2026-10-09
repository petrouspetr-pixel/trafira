let profiles=require("config.profiles"),transfer=require("config.profile_transfer"),transaction=require("service.config_transaction"),locks=require("service.operation_lock");
let jobs=require("config.profile_job");
function fail(error){return {success:false,error};}
function dispatch(request){
    if(request.action=="list")return profiles.list();
    if(request.action=="status")return jobs.status();
    if(request.action=="apply")return jobs.start(request,false);
    if(request.action=="restore")return jobs.start(request,true);
    if(request.action=="rename")return profiles.rename(request.id,request.name);
    if(request.action=="remove")return profiles.remove(request.id);
    if(request.action=="import_begin")return transfer.begin("i","");
    if(request.action=="import_chunk")return transfer.append(request.id,request.offset,request.data);
    if(request.action=="import_finish")return transfer.finish(request.id);
    if(request.action=="export_begin")return transfer.export_begin(request.id);
    if(request.action=="export_read")return transfer.read(request.id,request.offset);
    if(request.action=="transfer_cancel")return transfer.cancel(request.id);
    return fail("unsupported_action");
}
function action(text){
    if(type(text)!="string" || length(text)>65536)return fail("invalid_request");
    let request;
    try {request=json(text);}catch(e){return fail("invalid_request");}
    if(type(request)!="object" || type(request.action)!="string")return fail("invalid_request");
    for(let key in request)if(index(["action","id","name","digest","offset","data"],key)<0)return fail("invalid_request");
    if(request.action=="status" || request.action=="list")return dispatch(request);
    let lock=locks.acquire("profile-action");if(!lock)return fail("busy");
    let result;
    try {result=dispatch(request);}catch(e){result=fail("profile_operation_failed");}
    locks.release(lock);return result;
}
print(sprintf("%J\n",ARGV[0]=="worker"?jobs.worker(ARGV[1]):ARGV[0]=="action"?action(ARGV[1]):fail("unsupported_action")));
