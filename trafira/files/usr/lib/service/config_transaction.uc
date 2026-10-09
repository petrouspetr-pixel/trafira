let fs=require("fs"),locks=require("service.operation_lock"),hash=require("singbox.provenance").hash_file;
let storage=require("core.storage");
const DIRECTORY=getenv("TRAFIRA_TRANSACTION_DIR")||"/etc/trafira/transactions";
const TARGET=getenv("TRAFIRA_CONFIG_FILE")||"/etc/config/trafira";
const JOURNAL=DIRECTORY+"/active.json",BACKUP=DIRECTORY+"/original.uci";
const PREVIOUS=DIRECTORY+"/previous.uci",RESULT=DIRECTORY+"/result.json";
const MAX_FILE=1048576;

function failure(error) {return {success:false,error};}
function ensure() {
    let parent=substr(DIRECTORY,0,rindex(DIRECTORY,"/"));
    if(!fs.stat(parent) && !fs.mkdir(parent,448)) return false;
    let info=fs.lstat(DIRECTORY);
    if(info && info.type!="directory") return false;
    if(!info && !fs.mkdir(DIRECTORY,448)) return false;
    return fs.chmod(DIRECTORY,448);
}
function read(path,maximum) {
    let info=fs.lstat(path);
    if(!info || info.type!="file" || info.size>maximum) return null;
    let f=fs.open(path,"re");if(!f)return null;
    let text=f.read(maximum+1);f.close();
    return text!=null && length(text)<=maximum?text:null;
}
function object(path) {
    try {return json(read(path,4096));}catch(e){return null;}
}
function durable_write(path,text) {
    let info=fs.lstat(path);
    if(info && info.type!="file") return false;
    let temporary=path+".stage",staged=fs.lstat(temporary);
    if(staged) {
        if(staged.type!="file" || !fs.unlink(temporary)) return false;
    }
    let f=fs.open(temporary,"wex",384);if(!f)return false;
    let ok=f.write(text)==length(text);f.flush();f.close();
    if(!ok || read(temporary,MAX_FILE)!=text || system("sync")!=0) {fs.unlink(temporary);return false;}
    if(!fs.rename(temporary,path)) {fs.unlink(temporary);return false;}
    return system("sync")==0;
}
function journal(data) {return durable_write(JOURNAL,sprintf("%J",data));}
function finish(result) {
    result.running=false;
    if(!durable_write(RESULT,sprintf("%J",result))) return failure("result_write_failed");
    if(fs.lstat(JOURNAL) && (!fs.unlink(JOURNAL) || system("sync")!=0)) return failure("journal_cleanup_failed");
    return result;
}
function recover_locked(hooks) {
    let info=fs.lstat(JOURNAL);
    if(!info) return {success:true,restored:false};
    let state=object(JOURNAL),original=read(BACKUP,MAX_FILE);
    if(!state || state.schema!=1 || original==null || hash(BACKUP)!=state.original_digest)
        return {success:false,rollback_error:"invalid_recovery_backup"};
    if(!durable_write(TARGET,original)) return {success:false,rollback_error:"restore_write_failed"};
    if(hooks && !hooks.restore(state.service)) return {success:false,rollback_error:"restore_service_failed",restored:false};
    return finish({success:true,restored:true,job_id:state.job_id});
}
function recover(hooks) {
    let lock=locks.acquire("config-recover");if(!lock)return failure("busy");
    let result;
    try {result=ensure()?recover_locked(hooks):failure("storage_unavailable");}
    catch(e){result={success:false,rollback_error:"recovery_failed"};}
    locks.release(lock);return result;
}
function rollback_failure(error,hooks,job_id) {
    let restored=recover_locked(hooks);
    let result={success:false,error,restored:restored.success && restored.restored,job_id};
    if(!restored.success) result.rollback_error=restored.rollback_error||restored.error;
    durable_write(RESULT,sprintf("%J",result));
    return result;
}
function apply_locked(candidate_path,expected_digest,reason,hooks) {
    if(!ensure())return failure("storage_unavailable");
    if(fs.lstat(JOURNAL))return failure("recovery_required");
    if(type(hooks)!="object" || type(hooks.validate)!="function" || type(hooks.capture)!="function" || type(hooks.activate)!="function" || type(hooks.restore)!="function")return failure("missing_runtime_checks");
    if(!expected_digest || hash(TARGET)!=expected_digest)return failure("conflict");
    let original=read(TARGET,MAX_FILE),candidate=read(candidate_path,MAX_FILE);
    if(original==null || candidate==null)return failure("invalid_config_file");
    if(!hooks.validate(candidate_path))return failure("candidate_check_failed");
    if(read(candidate_path,MAX_FILE)!=candidate)return failure("candidate_changed");
    if(hash(TARGET)!=expected_digest)return failure("conflict");
    // Keep space for both backup copies, candidate staging and rollback staging.
    // Do not count bytes that deleting an old backup might eventually reclaim.
    let required=3*length(original)+length(candidate)+65536;
    let target_parent=substr(TARGET,0,rindex(TARGET,"/"));
    if(storage.available_bytes(DIRECTORY)<required || storage.available_bytes(target_parent)<required)
        return failure("insufficient_space");
    let service=hooks.capture();
    if(type(service)!="object" || type(service.running)!="bool" || type(service.enabled)!="bool")return failure("service_state_unavailable");
    let state={schema:1,job_id:sprintf("c-%x-%x",clock()[0],clock()[1]),worker:locks.identity(),original_digest:expected_digest,service,stage:"prepared"};
    if(!durable_write(BACKUP,original) || hash(BACKUP)!=expected_digest || !journal(state))return failure("backup_failed");
    // A crash after this point must restore BACKUP before the next startup.
    if(hash(TARGET)!=expected_digest) {finish(failure("conflict"));return failure("conflict");}
    if(!durable_write(TARGET,candidate))return rollback_failure("replace_failed",hooks,state.job_id);
    state.stage="replaced";
    if(!journal(state))return rollback_failure("journal_write_failed",hooks,state.job_id);
    if(service.running && !hooks.activate(service))return rollback_failure("activation_failed",hooks,state.job_id);
    if(!durable_write(PREVIOUS,original))return rollback_failure("previous_backup_failed",hooks,state.job_id);
    return finish({success:true,restored:false,job_id:state.job_id});
}
function apply(candidate_path,expected_digest,reason,hooks) {
    let lock=locks.acquire("config-apply");if(!lock)return failure("busy");
    let result;
    try {
        result=apply_locked(candidate_path,expected_digest,reason,hooks);
    } catch(e) {
        let recovery=recover_locked(hooks);
        result={success:false,error:"apply_failed",restored:recovery.restored||false,rollback_error:recovery.rollback_error};
    }
    locks.release(lock);return result;
}
function status() {
    let state=object(JOURNAL);
    if(fs.lstat(JOURNAL))return {running:true,recovery_pending:true,job_id:state?state.job_id:null};
    return object(RESULT)||{running:false};
}
function previous_path() {return PREVIOUS;}
function before_start() {
    if(!fs.lstat(JOURNAL))return {success:true};
    let state=object(JOURNAL);
    if(state && locks.is_live_ancestor(state.worker))return {success:true,active_transaction:true};
    return recover();
}
return {TARGET,apply,recover,status,previous_path,before_start};
