let profiles=require("config.profiles"),transfer=require("config.profile_transfer"),transaction=require("service.config_transaction"),locks=require("service.operation_lock");
let jobs=require("config.profile_job");
let fs=require("fs"),runtime=require("config.profile_runtime"),format=require("config.profile_format"),hash=require("singbox.provenance").hash_file;
function fail(error){return {success:false,error};}
function current_action(request){
    let work=jobs.new_directory();if(!work)return fail("storage_unavailable");
    let result;
    try {
        let digest=hash(transaction.TARGET);
        let current=runtime.read_document(transaction.TARGET,work.directory,request.action=="create"?request.name:"Current");
        if(!current.success)result=current;
        else if(!digest || hash(transaction.TARGET)!=digest)result=fail("conflict");
        else if(request.action=="create")result=profiles.create(current.document);
        else {
            let selected=profiles.export_profile(request.id);
            if(!selected.success)result=selected;
            else {
                let prepared=runtime.prepare(selected.document,work.directory);
                let applicable=prepared.success && runtime.hooks(selected.document,work.directory).validate(prepared.path);
                result={success:true,digest,name:selected.document.name,applicable,changes:format.diff(current.document.config,selected.document.config)};
                if(hash(transaction.TARGET)!=digest)result=fail("conflict");
            }
        }
    }catch(e){result=fail("profile_operation_failed");}
    jobs.cleanup(work.directory);return result;
}
function dispatch(request){
    if(request.action=="list")return {...profiles.list(),digest:hash(transaction.TARGET),can_restore:!!fs.stat(transaction.previous_path()) || !!transaction.status().recovery_pending};
    if(request.action=="create" || request.action=="preview")return current_action(request);
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
