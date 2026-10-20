// LAN API shared by Trafira dashboard, monitoring and node selection.
let common=require("core.common");
function config(settings,address) {
    let controller=common.as_string(address||"");
    return {external_controller:(controller!=""?controller:"127.0.0.1")+":9090"};
}
function apply(value,settings,address) {
    value.experimental=common.object_or_empty(value.experimental);
    let expected=config(settings,address),previous=value.experimental.clash_api;
    if(type(previous)=="object" && length(keys(previous))==1 && previous.external_controller==expected.external_controller)return false;
    value.experimental.clash_api=expected;
    return true;
}
function reconcile(path,settings,address) {
    let fs=require("fs"),provenance=require("singbox.provenance"),store=require("singbox.failure_store");
    let value=common.read_json_file(path);
    if(type(value)!="object")return false;
    let origins=provenance.load(path),base=store.load(path);
    // Never publish a corrected config while leaving digest-bound metadata stale.
    if(fs.lstat(path+".provenance.json") && !origins)return false;
    if(fs.lstat(path+".failure-policy.json") && !base)return false;
    if(!apply(value,settings,address))return true;
    if(!common.write_json_file(path,value))return false;
    if(origins && !provenance.save(path,origins))return false;
    if(base) {
        apply(base.config,settings,address);
        if(!store.save_base(path,base.config,base.sections))return false;
    }
    return true;
}
return {config,apply,reconcile};
