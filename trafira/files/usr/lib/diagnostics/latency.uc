// Explicit probe failures are UI evidence, scoped to one core/configuration.
let fs=require("fs");
function valid(value,group) {
    if(type(value)!="object")return false;
    if(!group)return type(value.delay)=="int" || type(value.delay)=="double" ? value.delay>0 : false;
    // URLTest returns an empty map when another automatic check is running.
    // This is no new measurement; do not invent failed nodes.
    for(let _,delay in value)
        if((type(delay)!="int" && type(delay)!="double") || !(delay>0))return false;
    return true;
}
function read(path,scope) {
    if(!scope)return {};
    let info=fs.lstat(path);
    if(!info || info.type!="file" || info.size>65536)return {};
    try {
        let value=json(fs.readfile(path));
        if(value.scope==scope && type(value.failed)=="object" && length(keys(value.failed))<=128)
            return value.failed;
    }catch(e){}
    return {};
}
function record(path,scope,tag,failed) {
    if(!scope || type(tag)!="string" || !length(tag) || length(tag)>128)return false;
    let info=fs.lstat(path+".lock");
    if(info && info.type!="file")return false;
    let lock=fs.open(path+".lock","ae",384);
    if(!lock)return false;
    if(!lock.lock("xn")){lock.close();return false;}
    let state=read(path,scope);
    if(failed) {
        if(!state[tag] && length(keys(state))>=128) {
            let oldest=null;
            for(let key,stamp in state)
                if(oldest==null || stamp<state[oldest])oldest=key;
            delete state[oldest];
        }
        state[tag]=time();
    }else delete state[tag];
    let temp=path+".new",entry=fs.lstat(temp);
    let ok=false;
    if(!entry || entry.type=="file") {
        let file=fs.open(temp,"we",384);
        if(file) {
            let data=sprintf("%J",{scope,failed:state});
            ok=file.write(data)==length(data);
            file.close();
            ok=ok && fs.rename(temp,path);
        }
    }
    lock.close();
    return !!ok;
}
function apply(proxies,path,scope) {
    let state=read(path,scope);
    for(let tag,proxy in proxies) {
        delete proxy.trafira_latency_failed;
        // A newer successful automatic probe is authoritative.
        if(state[tag] && type(proxy.history)=="array" && !length(proxy.history))
            proxy.trafira_latency_failed=true;
    }
}
function failures(path,scope) {return keys(read(path,scope));}
return {valid,record,apply,failures};
