// SPDX-License-Identifier: GPL-3.0-only
let fs=require("fs"),model=require("integrations.warp_model"),transport=require("integrations.warp_transport"),runtime=require("config.profile_runtime");
let transaction=require("service.config_transaction"),jobs=require("config.profile_job"),format=require("config.profile_format"),hash=require("singbox.provenance").hash_file;
const STATE=getenv("TRAFIRA_WARP_STATE")||"/etc/trafira-warp";
const RUN=getenv("TRAFIRA_WARP_RUNTIME")||"/var/run/trafira-warp";
function fail(error){return {success:false,error};}
function private_write(path,text) {
    let old=fs.lstat(path);if(old && old.type!="file")return false;
    let f=fs.open(path,"we",384);if(!f)return false;
    let ok=f.write(text)==length(text);f.close();return ok && fs.chmod(path,384) && fs.readfile(path)==text;
}
function preview(request,state) {
    if(transaction.status().recovery_pending)return fail("recovery_required");
    let work=jobs.new_directory();if(!work)return fail("storage_unavailable");
    let result;
    try {
        let digest=hash(transaction.TARGET),source=runtime.read_document(transaction.TARGET,work.directory,"WARP");
        if(!source.success)result=source;
        else {
            let live=transport.read(),removal=request.action=="preview_detach",section=filter(source.document.config,(s)=>s[".type"]=="section" && s.warp_owner=="trafira-warp")[0];
            let candidate=removal?model.detach(source.document,(section||{})[".name"],digest,digest):model.attach(source.document,live,digest,digest);
            if(!candidate.success)result=candidate;
            else {
                let prepared=runtime.prepare(candidate.document,work.directory),applicable=prepared.success && runtime.hooks(candidate.document,work.directory).validate(prepared.path);
                if(hash(transaction.TARGET)!=digest)result=fail("conflict");
                else if(!applicable)result=fail("candidate_check_failed");
                else {
                    let stored=state.load(STATE+"/transport.json"),id="p-"+work.id;
                    let value={preview_id:id,expected_digest:digest,generation:stored?.generation||0,expires_at:clock()[0]+900,action:removal?"detach":"attach",section:candidate.section,document:candidate.document};
                    result=state.save(RUN+"/preview.json",value)?{success:true,preview_id:id,expected_digest:digest,section:candidate.section,changes:format.diff(source.document.config,candidate.document.config),removal}:fail("storage_unavailable");
                }
            }
        }
    }catch(e){result=fail("preview_failed");}
    jobs.cleanup(work.directory);return result;
}
function validate(request,state) {
    let preview=state.load(RUN+"/preview.json"),current=state.load(STATE+"/transport.json");
    if(!preview || preview.preview_id!=request.preview_id || preview.expected_digest!=request.expected_digest || hash(transaction.TARGET)!=request.expected_digest || preview.action!=request.action || preview.generation!=(current?.generation||0) || preview.expires_at<clock()[0])return fail("conflict");
    if(request.action=="attach") {let live=transport.read();if(!live.running || !live.https_ok || !live.warp)return fail("transport_unhealthy");}
    return {success:true};
}
function apply(request,state) {
    let validation=validate(request,state);if(!validation.success)return validation;
    let preview=state.load(RUN+"/preview.json"),work=jobs.new_directory();if(!work)return fail("storage_unavailable");
    let prepared=runtime.prepare(preview.document,work.directory),result;
    try {result=prepared.success?transaction.apply(prepared.path,request.expected_digest,"warp",runtime.hooks(preview.document,work.directory)):prepared;}
    catch(e){result=fail("apply_failed");}
    jobs.cleanup(work.directory);if(result.success)state.remove(RUN+"/preview.json");return result;
}
function capture() {
    if(transaction.status().recovery_pending)die("recovery_required");
    let info=fs.lstat(transaction.TARGET);if(!info || info.type!="file" || info.size>1048576)die("configuration_unavailable");
    let text=fs.readfile(transaction.TARGET),digest=hash(transaction.TARGET);
    if(text==null || !digest || text!=fs.readfile(transaction.TARGET))die("configuration_unavailable");
    return {text,digest,service:runtime.hooks(null,"").capture()};
}
function restore(saved) {
    if(!saved || type(saved.text)!="string")return false;
    let base=runtime.hooks(null,"");
    if(transaction.status().recovery_pending && !transaction.recover(base).success)return false;
    if(hash(transaction.TARGET)==saved.digest)return base.restore(saved.service);
    let work=jobs.new_directory();if(!work)return false;
    let ok=false;
    try {
        if(private_write(work.directory+"/original",saved.text)) {
            let source=runtime.read_document(work.directory+"/original",work.directory,"Restore WARP");
            if(source.success) {
                let prepared=runtime.prepare(source.document,work.directory),hooks=runtime.hooks(source.document,work.directory);
                hooks.capture=()=>({running:false,enabled:saved.service.enabled});
                ok=prepared.success && transaction.apply(prepared.path,hash(transaction.TARGET),"warp-restore",hooks).success && base.restore(saved.service);
            }
        }
    }catch(e){}
    jobs.cleanup(work.directory);return ok;
}
function references() {
    let config=require("core.uci"),sections=[];
    for(let type_name in format.TYPES)for(let section in config.section_objects("trafira",type_name))push(sections,section);
    return sections;
}
return {preview,validate,apply,capture,restore,references};
