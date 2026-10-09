// Private checkpoint of verified runtime settings, never returned through RPC.
let fs=require("fs"),store=require("singbox.failure_store"),common=require("core.common"),hash=require("singbox.provenance").hash_file;
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
const PATH=ROOT+"/applied-config.json";
const CONFIG=getenv("TRAFIRA_CONFIG_FILE")||"/etc/config/trafira";
function text(){let info=fs.lstat(CONFIG);return info && info.type=="file" && info.size<=1048576?fs.readfile(CONFIG):null;}
function normalized(value){return join("\n",filter(split(value||"","\n"),(line)=>!match(line,/^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/)));}
function capture(settings,sections){
    let source=text();if(source==null)return null;
    let selected={};
    for(let key in ["config_path","router_origin_enabled","router_origin_section","alice_mode_enabled","alice_list_mode","alice_ips","alice_macs","alice_interfaces","source_network_interfaces","exclude_wifi_calling"])
        if(settings[key]!=null)selected[key]=settings[key];
    selected.config_path=selected.config_path||"/etc/sing-box/config.json";
    let protected=false;
    for(let section in sections||[])if(common.bool_option(section,"enabled",true) && section.failure_policy && section.failure_policy!="legacy")protected=true;
    return {schema:1,config_text:source,settings:selected,protected};
}
function save(candidate){
    if(!candidate || normalized(text())!=normalized(candidate.config_text))return false;
    let digest=hash(candidate.settings.config_path);if(!digest)return false;
    let info=fs.lstat(ROOT);if(info && info.type!="directory")return false;
    if(!info && !fs.mkdir(ROOT,493))return false;
    return store.write(PATH,{...candidate,config_text:text(),config_digest:digest});
}
function read(){
    let value=store.read(PATH);
    return value && value.schema==1 && type(value.config_text)=="string" && length(value.config_text)<=1048576 && type(value.settings)=="object"?value:null;
}
function active(){let value=read();return value && hash(value.settings.config_path)==value.config_digest?value:null;}
function refresh(path){let value=read();return value && value.settings.config_path==path && store.write(PATH,{...value,config_digest:hash(path)});}
return {capture,save,read,active,refresh,normalized};
