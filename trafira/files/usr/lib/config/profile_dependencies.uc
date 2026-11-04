// Bounded inspection of a saved profile. Never execute profile values or read
// referenced file contents; this is an inventory, not runtime validation.
let fs=require("fs"),format=require("config.profile_format"),common=require("core.common");
const MAX_FILES=64,MAX_NODES=8192,MAX_DEPTH=12,MAX_JSON=262144;
const PATH_KEYS={dns_mtls_client_certificate:"certificate",dns_mtls_client_key:"private_key",tls_certificate_path:"certificate",tls_key_path:"private_key",certificate_path:"certificate",key_path:"private_key",client_certificate_path:"certificate",client_key_path:"private_key"};
const LIST_KEYS=["rule_set","rule_set_with_subnets","domain_ip_lists"];
const JSON_KEYS=["outbound_json","outbound_jsons","inbound_json"];
function valid_path(path){
    if(type(path)!="string" || length(path)<2 || length(path)>512 || substr(path,0,1)!="/" || substr(path,0,2)=="//")return false;
    // POSIX regex rejects a NUL range on the pinned OpenWrt ucode runtime.
    for(let i=0;i<length(path);i++){let code=ord(path,i);if(code<32 || code==127)return false;}
    return true;
}
function inspect(document,hooks){
    if(!format.validate(document).valid)return {success:false,error:"invalid_profile"};
    let report={schema:1,counts:{},components:[],files:[],warnings:["profile_not_full_backup","runtime_not_validated"],limited:false};
    let requirements={sing_box:{required:true,requirement:"any"}},known={},active={},nodes=0;
    function warning(value){if(index(report.warnings,value)<0)push(report.warnings,value);}
    function limit(){report.limited=true;warning("inspection_limited");}
    function component(id,required,requirement){
        let entry=requirements[id]||{required:false,requirement:"any"};
        entry.required=entry.required||required;
        if(requirement=="extended" && required)entry.requirement="extended";
        requirements[id]=entry;
    }
    function file(value,kind,required){
        if(!valid_path(value)){warning("invalid_path");return;}
        let key=kind+":"+value;
        if(known[key]!=null){report.files[known[key]].required=report.files[known[key]].required||required;return;}
        if(length(report.files)>=MAX_FILES){limit();return;}
        let status="unknown";
        try{status=hooks.file(value);}catch(e){}
        if(index(["present","missing","not_regular","unknown"],status)<0)status="unknown";
        known[key]=length(report.files);
        push(report.files,{kind,path:value,required,status,included:false});
    }
    function scan(value,required,depth){
        if(++nodes>MAX_NODES || depth>MAX_DEPTH){limit();return;}
        if(type(value)=="array") {
            for(let child in value){if(nodes>=MAX_NODES){limit();break;}scan(child,required,depth+1);}
        } else if(type(value)=="object") {
            required=required && value.enabled!==false;
            if(value.type=="local" && value.path)file(value.path,"rule_set",required);
            if(value.type=="mtproto" || value.type=="fallback" || value.type=="xhttp")component("sing_box",required,"extended");
            for(let key,child in value){
                if(nodes>=MAX_NODES){limit();break;}
                if(PATH_KEYS[key] && child)file(child,PATH_KEYS[key],required);
                scan(child,required,depth+1);
            }
        }
    }
    for(let section in document.config) {
        let kind=section[".type"];
        report.counts[kind]=(report.counts[kind]||0)+1;
        if(kind=="section" || kind=="server")active[section[".name"]]=common.bool_option(section,"enabled",kind=="section");
    }
    for(let section in document.config) {
        let kind=section[".type"],required=kind=="settings"?true:active[section[".name"]]||false;
        if(section.section)required=active[section.section]||false;
        if(index(["zapret","zapret2","byedpi"],section.action)>=0)component(section.action,required,"any");
        if((kind=="priority_group" && section.implementation=="native_fallback") || (kind=="server" && section.protocol=="mtproto"))component("sing_box",required,"extended");
        let connection=kind=="section" && index(["connection","proxy","outbound","vpn"],section.action)>=0;
        let plural=section.outbound_jsons;
        let has_plural=type(plural)=="array"?length(plural)>0:plural!=null && common.as_string(plural)!="";
        for(let key,value in section) {
            if(++nodes>MAX_NODES){limit();break;}
            if(PATH_KEYS[key] && value) {
                let needed=required;
                if(key=="dns_mtls_client_certificate" || key=="dns_mtls_client_key")needed=common.bool_option(section,"dns_mtls_enabled",false);
                if(key=="tls_certificate_path" || key=="tls_key_path")needed=required && kind=="server" && require("singbox.servers").effective_security(section,common.option(section,"protocol","vless"))=="tls";
                file(value,PATH_KEYS[key],needed);
            }
            if(index(LIST_KEYS,key)>=0)for(let reference in common.list_option(section,key))
                if(type(reference)=="string" && substr(reference,0,1)=="/")file(reference,key=="domain_ip_lists"?"domain_list":"rule_set",required);
            if(index(JSON_KEYS,key)>=0) {
                for(let raw in type(value)=="array"?value:[value]) {
                    if(type(raw)=="string" && !length(trim(raw)))continue;
                    warning("custom_json_review");
                    if(type(raw)!="string" || length(raw)>MAX_JSON){limit();continue;}
                    let needed=required && (key=="inbound_json"?kind=="server" && section.protocol=="json_inbound":connection && !(key=="outbound_json" && has_plural));
                    try{scan(json(raw),needed,0);}catch(e){warning("invalid_custom_json");}
                }
            }
            if(key=="selector_proxy_links" && connection)for(let link in common.list_option(section,key))
                if(type(link)=="string" && match(link,/[?&]type=xhttp([&#]|$)/))component("sing_box",required,"extended");
            if(value && (key=="nfqws_opt" || key=="nfqws2_opt" || key=="byedpi_cmd_opts"))warning("strategy_files_review");
        }
        if(nodes>=MAX_NODES){limit();break;}
    }
    for(let id,requirement in requirements) {
        let info={};try{info=hooks.component(id)||{};}catch(e){}
        let status=info.available===true?"present":info.available===false?"missing":"unknown";
        let variant=index(["extended","standard"],info.variant)>=0?info.variant:"unknown";
        if(requirement.requirement=="extended" && status=="present")status=variant=="extended"?"present":variant=="standard"?"incompatible":"unknown";
        let version=type(info.version)=="string" && match(info.version,/^[0-9][A-Za-z0-9._+~-]{0,95}$/)?info.version:"";
        push(report.components,{id,...requirement,status,version,variant});
    }
    report.missing=length(filter([...report.files,...report.components],entry=>entry.required && index(["missing","not_regular","incompatible"],entry.status)>=0));
    return {success:true,report};
}
function file_status(path){let info=fs.stat(path);return !info?"missing":info.type=="file"?"present":"not_regular";}
function quote(value){return "'"+replace(value,/'/g,"'\\''")+"'";}
function component_status(id){
    let constants=require("core.constants");
    let binaries={sing_box:"/usr/bin/sing-box",zapret:constants.ZAPRET_NFQWS_BIN,zapret2:constants.ZAPRET2_NFQWS2_BIN,byedpi:getenv("BYEDPI_BIN")||"/usr/bin/ciadpi"};
    let binary=binaries[id],info=fs.stat(binary);
    if(!info || info.type!="file" || system("test -x "+quote(binary),1000)!=0)return {available:false};
    let version="",variant="unknown";
    // The timeout and executable are fixed local tools, never profile values.
    if(system("command -v timeout >/dev/null 2>&1",1000)==0) {
        let handle=fs.popen("timeout 2 "+quote(binary)+(id=="sing_box"?" version":" --version")+" 2>/dev/null","re");
        if(handle) {
            let text=handle.read(4096)||"",status=handle.close();
            if(status==0){let matched=match(text,/(^|[ \t])v?([0-9]+[.][0-9][A-Za-z0-9._+~-]*)/);if(matched)version=matched[2];}
            if(id=="sing_box" && version)variant=index(lc(version),"extended")>=0?"extended":"standard";
        }
    }
    return {available:true,version,variant};
}
function report(id){
    let saved=require("config.profiles").export_profile(id);
    return saved.success?inspect(saved.document,{file:file_status,component:component_status}):saved;
}
return {inspect,report};
