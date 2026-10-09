// SPDX-License-Identifier: Apache-2.0
let fs=require("fs");
const DIRECTORY=getenv("TRAFIRA_WARP_STATE")||"/etc/trafira-warp";
const RUNTIME=getenv("TRAFIRA_WARP_RUNTIME")||"/var/run/trafira-warp";
function ensure(directory) {
    if(directory!=DIRECTORY && directory!=RUNTIME)return false;
    let info=fs.lstat(directory);
    return (!info?fs.mkdir(directory,448):info.type=="directory") && fs.chmod(directory,448);
}
function permitted(path) {
    if(type(path)!="string")return false;
    let slash=rindex(path,"/"),directory=substr(path,0,slash),name=substr(path,slash+1);
    return index([DIRECTORY,RUNTIME],directory)>=0 && match(name,/^[a-zA-Z0-9_-]+\.(json|conf)$/);
}
function load(path) {
    if(!permitted(path))return null;
    let info=fs.lstat(path);
    if(!info || info.type!="file" || info.size>2097152)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let text=file.read(2097153);file.close();
    if(length(text||"")>2097152)return null;
    try {let value=json(text);return type(value)=="object"?value:null;}catch(e){return null;}
}
function save_text(path,text) {
    if(!permitted(path) || type(text)!="string")return false;
    let directory=substr(path,0,rindex(path,"/"));if(!ensure(directory))return false;
    let old=fs.lstat(path);if(old && old.type!="file")return false;
    if(length(text)>2097152)return false;
    let temporary=path+".stage",stale=fs.lstat(temporary);
    if(stale && (stale.type!="file" || !fs.unlink(temporary)))return false;
    let file=fs.open(temporary,"wex",384);if(!file)return false;
    let ok=file.write(text)==length(text);file.close();
    if(!ok || fs.readfile(temporary)!=text){fs.unlink(temporary);return false;}
    // Persist the staged backup before committing the journal which refers to it.
    if(directory==DIRECTORY && system("sync")!=0)return false;
    if(!fs.rename(temporary,path))return false;
    return directory!=DIRECTORY || system("sync")==0;
}
function save(path,value){return type(value)=="object" && save_text(path,sprintf("%J",value));}
function remove(path) {
    if(!permitted(path))return false;
    let info=fs.lstat(path);if(!info)return true;
    if(info.type!="file" || !fs.unlink(path))return false;
    return substr(path,0,length(DIRECTORY)+1)!=DIRECTORY+"/" || system("sync")==0;
}
function public_status(value) {
    value=type(value)=="object"?value:{};
    let result={success:value.success!==false,running:value.running===true};
    for(let key in ["restored","recovery_pending","registered","enabled","https_ok","warp","rollback_error"])
        if(type(value[key])=="bool")result[key]=value[key];
    for(let key in ["job_id","candidate_id","preview_id","expected_digest","section","error","stage","interface","owner","mode"])
        if(type(value[key])=="string" && match(value[key],/^[a-zA-Z0-9_-]{1,96}$/))result[key]=value[key];
    for(let key in ["schema","generation","started_at","completed_at","handshake_age"])
        if(type(value[key])=="int" && value[key]>=0)result[key]=value[key];
    return result;
}
return {DIRECTORY,RUNTIME,ensure,load,save,save_text,remove,public_status};
