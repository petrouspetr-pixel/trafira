// Managed Clash API/UI settings shared by generation and final publication.
let common=require("core.common"),constants=require("singbox.constants");
const UI_PATH="/usr/share/sing-box/ui";
// Pin compiled upstream files: enabling the panel must not follow a moving branch.
const UI_URL="https://github.com/MetaCubeX/Yacd-meta/archive/8402051bc17496e827f9a9fe808139cc10ad20be.zip";
function config(settings,address) {
    let enabled=common.bool_option(settings,"enable_yacd",false);
    let controller=common.as_string(address||"");
    if(enabled && common.bool_option(settings,"enable_yacd_wan_access",false))controller="0.0.0.0";
    else if(controller=="")controller="127.0.0.1";
    let result={external_controller:controller+":9090"};
    if(enabled) {
        result.external_ui=UI_PATH;
        result.external_ui_download_url=UI_URL;
        let section=common.bool_option(settings,"download_components_via_proxy",false)?common.option(settings,"download_components_via_proxy_section",""):"";
        result.external_ui_download_detour=section!=""?constants.outbound_tag(section):constants.DIRECT_OUTBOUND_TAG;
        let secret=common.option(settings,"yacd_secret_key","");
        if(secret!="")result.secret=secret;
    }
    return result;
}
function apply(value,settings,address) {
    value.experimental=common.object_or_empty(value.experimental);
    value.experimental.clash_api=common.object_or_empty(value.experimental.clash_api);
    let api=value.experimental.clash_api,expected=config(settings,address),changed=false;
    for(let key in ["external_controller","external_ui","external_ui_download_url","external_ui_download_detour","secret"]) {
        if(api[key]==expected[key])continue;
        changed=true;
        if(expected[key]==null)delete api[key];else api[key]=expected[key];
    }
    return changed;
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
