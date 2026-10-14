// RAM-only compact scenario results. Neither requests nor arbitrary caller paths are accepted.
let fs=require("fs"),hash=require("singbox.provenance").hash_file;
const ROOT=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/route-decode-cache";
const MAX_FILE=4*1024*1024,MAX_TOTAL=256*1024;
const MAX_ENTRY=4096;
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
    for(let name in fs.lsdir(ROOT)||[])if(match(name,/^[a-f0-9]{64}[.]json$/)) {
        let info=fs.lstat(ROOT+"/"+name);
        if(info && info.type=="file" && info.size>MAX_ENTRY){fs.unlink(ROOT+"/"+name);fs.unlink(ROOT+"/"+substr(name,0,64)+".meta");}
    }
    return fs.chmod(ROOT,448);
}
function identity(){
    let pipe=fs.popen("command -v sing-box","re");if(!pipe)return null;
    let path=trim(pipe.read(1024)||""),status=pipe.close();
    let digest=status==0 && path!=""?hash(path):null;
    return digest?{path,digest}:null;
}
function cache_key(digest,format,core){
    let pipe=fs.popen("printf %s "+quote("route-v2\n"+digest+"\n"+format+"\n"+core)+" | sha256sum","re");
    if(!pipe)return null;
    let output=pipe.read(128),status=pipe.close(),found=match(output||"",/^([a-f0-9]{64}) /);
    return status==0 && found?found[1]:null;
}
function get(key,budget){
    if(!key || !ensure())return null;
    let path=ROOT+"/"+key+".json",info=fs.lstat(path),metadata=read(ROOT+"/"+key+".meta",256);
    if(!info || info.type!="file" || !metadata || type(metadata.digest)!="string" || !match(metadata.digest,/^[a-f0-9]{64}$/) || hash(path)!=metadata.digest)return null;
    if(info.size>budget)return {error:"size_limit"};
    let entry=read(path,min(MAX_FILE+1024,budget));
    return entry && entry.schema==1 && entry.key==key && type(entry.data)=="object" && type(entry.data.match)=="object" && index(["yes","no","unknown"],entry.data.match.value)>=0 && type(entry.data.match.missing)=="array" && hash(path)==metadata.digest?{data:entry.data,bytes:info.size}:null;
}
function put(key,data,workspace){
    if(!key || !ensure())return false;
    let text=sprintf("%J",{schema:1,key,data});if(length(text)>MAX_ENTRY)return false;
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
    while(length(entries) && (total+length(text)+128>MAX_TOTAL || length(entries)>=128)) {
        let old=shift(entries);
        if(!fs.unlink(ROOT+"/"+old.name))return false;
        fs.unlink(ROOT+"/"+substr(old.name,0,64)+".meta");
        total-=old.bytes;
    }
    if(total+length(text)+128>MAX_TOTAL)return false;
    let temporary=workspace+"/cache.stage";
    let file=fs.open(temporary,"wex",384);if(!file)return false;
    let ok=file.write(text)==length(text);file.close();
    let digest=ok?hash(temporary):null,meta=temporary+".meta",output=digest?fs.open(meta,"wex",384):null;
    if(!output)ok=false;
    else {let data=sprintf("%J",{digest});ok=output.write(data)==length(data);output.close();}
    if(ok)ok=fs.rename(temporary,ROOT+"/"+key+".json") && fs.rename(meta,ROOT+"/"+key+".meta");
    fs.unlink(temporary);fs.unlink(meta);return !!ok;
}
// Workspace is supplied by the private supervisor, never by an RPC request.
function cleanup(workspace){
    let marker=fs.lstat(workspace+"/codec.pid");
    if(marker && marker.type=="file" && marker.size<128){
        let fields=split(trim(fs.readfile(workspace+"/codec.pid")||""),/\s+/);
        let alive=length(fields)==2?require("service.operation_lock").identity(fields[0]):null;
        if(alive && alive.ticks==fields[1])system("kill -KILL "+alive.pid+" 2>/dev/null");
    }
    for(let name in ["codec.pid","decode-output","cache.stage","cache.stage.meta"]){
        let path=workspace+"/"+name,info=fs.lstat(path);
        if(info && info.type=="file")fs.unlink(path);
    }
}
function decode(path,format,milliseconds,budget,workspace){
    let limit=min(MAX_FILE,budget),temporary=workspace+"/decode-output";
    if(limit<=0)return {error:"size_limit"};
    let input=fs.stat(path);
    if(format=="source" && input && input.size>limit)return {error:"size_limit"};
    let file=fs.open(temporary,"wex",384);
    if(!file)return {error:"storage_unavailable"};file.close();
    // Record the timed native child identity so the supervisor can clean up after SIGKILL.
    let marker=workspace+"/codec.pid",owner=require("service.operation_lock").identity();
    let verify="if ! awk -v ticks="+quote(owner.ticks)+" '{exit($22 != ticks || $3 == \"Z\")}' /proc/"+owner.pid+"/stat 2>/dev/null; then rm -f "+quote(marker)+" "+quote(temporary)+"; exit 1; fi; ";
    let command="ulimit -Sv unlimited; umask 077; ticks=$(awk '{print $22}' /proc/$$/stat); printf '%s %s' $$ \"$ticks\" > "+quote(marker)+"; "+verify+"ulimit -f "+int((limit+511)/512)+"; exec sing-box rule-set "+(format=="source"?"compile":"decompile")+" "+quote(path)+" -o "+quote(temporary)+" >/dev/null 2>&1";
    let started=clock(true),status=system(command,milliseconds),ended=clock(true);
    let target=format=="source"?path:temporary,info=fs.stat(target);
    let data=status==0 && info && info.size<=limit?read(target,limit,format=="source"):null;
    fs.unlink(temporary);fs.unlink(marker);
    let elapsed=(ended[0]-started[0])*1000+(ended[1]-started[1])/1000000;
    if(status==-9 && elapsed>=milliseconds-100)return {error:"decode_timeout"};
    if(status==-25 || (info && info.size>limit))return {error:"size_limit"};
    return type(data)=="object" && type(data.rules)=="array"?{data,bytes:info.size}:{error:"decode_failed"};
}
// Only callers with a verified domain-only provider may use this CLI: it does
// not accept the full connection metadata needed by arbitrary rule sets.
function match_domain(path,domain,milliseconds,workspace){
    if(type(domain)!="string" || !match(domain,/^[A-Za-z0-9][A-Za-z0-9.-]*$/))return {error:"decode_failed"};
    let temporary=workspace+"/decode-output",marker=workspace+"/codec.pid";
    let file=fs.open(temporary,"wex",384);if(!file)return {error:"storage_unavailable"};file.close();
    let owner=require("service.operation_lock").identity();
    let verify="if ! awk -v ticks="+quote(owner.ticks)+" '{exit($22 != ticks || $3 == \"Z\")}' /proc/"+owner.pid+"/stat 2>/dev/null; then rm -f "+quote(marker)+" "+quote(temporary)+"; exit 1; fi; ";
    let command="ulimit -Sv unlimited; umask 077; ticks=$(awk '{print $22}' /proc/$$/stat); printf '%s %s' $$ \"$ticks\" > "+quote(marker)+"; "+verify+"ulimit -f 128; exec sing-box rule-set match -f binary "+quote(path)+" "+quote(domain)+" >"+quote(temporary)+" 2>&1";
    let status=system(command,milliseconds),info=fs.lstat(temporary),text=status==0 && info && info.type=="file" && info.size<=65536?fs.readfile(temporary):null;
    fs.unlink(temporary);fs.unlink(marker);
    if(text==null)return {error:"decode_failed"};
    if(text=="")return {match:{value:"no",missing:[]}};
    for(let line in split(text,"\n"))if(match(line,/^match rules[.]\[[0-9]+\]: /))return {match:{value:"yes",missing:[]}};
    return {error:"decode_failed"};
}
return {identity,cache_key,get,put,decode,match_domain,cleanup,MAX_FILE,MAX_TOTAL};
