// RAM-only validated exports. Neither requests nor arbitrary caller paths are accepted.
let fs=require("fs"),hash=require("singbox.provenance").hash_file;
const ROOT=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/route-decode-cache";
const MAX_FILE=16*1024*1024,MAX_TOTAL=32*1024*1024;
function quote(v){return "'"+replace(""+v,/'/g,"'\\''")+"'";}
function read(path,limit,follow){
    let info=follow?fs.stat(path):fs.lstat(path);if(!info || info.type!="file" || info.size>limit)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let raw=file.read(limit+1);file.close();
    if(length(raw||"")>limit)return null;
    try{return json(raw);}catch(e){return null;}
}
function ensure(){
    let info=fs.lstat(ROOT);if(info && info.type!="directory")return false;
    if(!info && !fs.mkdir(ROOT,448))return false;
    return fs.chmod(ROOT,448);
}
function identity(){
    let pipe=fs.popen("command -v sing-box","re");if(!pipe)return null;
    let path=trim(pipe.read(1024)||""),status=pipe.close();
    let digest=status==0 && path!=""?hash(path):null;
    return digest?{path,digest}:null;
}
function cache_key(digest,format,core){
    let pipe=fs.popen("printf %s "+quote("route-v1\n"+digest+"\n"+format+"\n"+core)+" | sha256sum","re");
    if(!pipe)return null;
    let output=pipe.read(128),status=pipe.close(),found=match(output||"",/^([a-f0-9]{64}) /);
    return status==0 && found?found[1]:null;
}
function get(key){
    if(!key || !ensure())return null;
    let path=ROOT+"/"+key+".json",info=fs.lstat(path),metadata=read(ROOT+"/"+key+".meta",256);
    if(!info || info.type!="file" || !metadata || type(metadata.digest)!="string" || !match(metadata.digest,/^[a-f0-9]{64}$/) || hash(path)!=metadata.digest)return null;
    let entry=read(path,MAX_FILE+1024);
    return entry && entry.schema==1 && entry.key==key && type(entry.data)=="object" && type(entry.data.rules)=="array"?entry.data:null;
}
function put(key,data){
    if(!key || !ensure())return false;
    let text=sprintf("%J",{schema:1,key,data});if(length(text)>MAX_FILE)return false;
    let entries=[],total=0;
    for(let name in fs.lsdir(ROOT)||[]) {
        if(!match(name,/^[a-f0-9]{64}[.]json$/))continue;
        let info=fs.lstat(ROOT+"/"+name);
        if(!info || info.type!="file")continue;
        let meta=fs.lstat(ROOT+"/"+substr(name,0,64)+".meta"),bytes=info.size+(meta && meta.type=="file"?meta.size:0);
        total+=bytes;push(entries,{name,bytes,mtime:info.mtime});
    }
    // One worker owns publication; evict only this component's regular entries.
    entries=sort(entries,(a,b)=>a.mtime-b.mtime);
    while(length(entries) && (total+length(text)+128>MAX_TOTAL || length(entries)>=256)) {
        let old=shift(entries);
        if(!fs.unlink(ROOT+"/"+old.name))return false;
        fs.unlink(ROOT+"/"+substr(old.name,0,64)+".meta");
        total-=old.bytes;
    }
    if(total+length(text)+128>MAX_TOTAL)return false;
    let now=clock(),temporary=ROOT+"/"+key+"."+sprintf("%x-%x",now[0],now[1])+".stage";
    let file=fs.open(temporary,"wex",384);if(!file)return false;
    let ok=file.write(text)==length(text);file.close();
    let digest=ok?hash(temporary):null,meta=temporary+".meta",output=digest?fs.open(meta,"wex",384):null;
    if(!output)ok=false;
    else {let data=sprintf("%J",{digest});ok=output.write(data)==length(data);output.close();}
    if(ok)ok=fs.rename(temporary,ROOT+"/"+key+".json") && fs.rename(meta,ROOT+"/"+key+".meta");
    fs.unlink(temporary);fs.unlink(meta);return !!ok;
}
function decode(path,format,milliseconds){
    let pipe=fs.popen("umask 077; mktemp /tmp/trafira-route-decode.XXXXXX","re");
    if(!pipe)return {error:"storage_unavailable"};
    let temporary=trim(pipe.read(256)||"");
    if(pipe.close()!=0 || !match(temporary,/^\/tmp\/trafira-route-decode[.][A-Za-z0-9]+$/))return {error:"storage_unavailable"};
    // exec makes the native codec the timed child. No shell watchdog or RPC pipe remains.
    let command="ulimit -f 32768; exec sing-box rule-set "+(format=="source"?"compile":"decompile")+" "+quote(path)+" -o "+quote(temporary)+" >/dev/null 2>&1";
    let status=system(command,milliseconds),target=format=="source"?path:temporary,info=fs.stat(target);
    let data=status==0?read(target,MAX_FILE,format=="source"):null;
    fs.unlink(temporary);
    if(status==-9)return {error:"decode_timeout"};
    if(status==-25 || (info && info.size>MAX_FILE))return {error:"size_limit"};
    return type(data)=="object" && type(data.rules)=="array"?{data,bytes:info.size}:{error:"decode_failed"};
}
return {identity,cache_key,get,put,decode,MAX_FILE,MAX_TOTAL};
