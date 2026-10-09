let fs=require("fs"),versions=require("components.core_versions");
const DIRECTORY=getenv("TRAFIRA_CORE_CATALOG_DIR")||"/var/run/trafira/core-catalog";
const LIMIT=2097152;
function path(env) {
    if(type(env)!="object")return null;
    for(let field in ["variant","architecture","package_type"])
        if(type(env[field])!="string" || !match(env[field],/^[A-Za-z0-9_.+-]{1,128}$/))return null;
    return DIRECTORY+"/"+join("~",[env.variant,env.architecture,env.package_type])+".json";
}
function read(file) {
    let stat=fs.lstat(file);if(!stat || stat.type!="file" || stat.size>LIMIT)return null;
    let stream=fs.open(file,"re");if(!stream)return null;
    let text=stream.read(LIMIT+1);stream.close();
    if(text==null || length(text)>LIMIT)return null;
    try {return json(text);}catch(e){return null;}
}
function store(file,data) {
    let dir=fs.lstat(DIRECTORY);
    if(dir && dir.type!="directory")return false;
    if(!dir && !fs.mkdir(DIRECTORY,448))return false;
    if(!fs.chmod(DIRECTORY,448))return false;
    let text=sprintf("%J",data);if(length(text)>LIMIT)return false;
    let temp=file+sprintf(".%x-%x",clock()[0],clock()[1]);
    let f=fs.open(temp,"wex",384);if(!f)return false;
    let ok=f.write(text)==length(text);f.close();
    if(!ok || fs.readfile(temp)!=text || !fs.rename(temp,file)){fs.unlink(temp);return false;}
    return true;
}
function response(data,env) {
    return {...versions.catalog(data.releases,env),success:true,cached_at:data.cached_at};
}
function load(env,refresh,fetch,now) {
    let file=path(env);if(!file)return {success:false,error:"invalid_environment",entries:[]};
    now=now==null?clock()[0]:now;
    let cached=read(file);
    if(cached && (type(cached.cached_at)!="int" || type(cached.releases)!="array" || versions.catalog(cached.releases,env).unavailable_reason=="catalog_too_large"))cached=null;
    if(!refresh && cached && now>=cached.cached_at && now-cached.cached_at<900)return response(cached,env);
    let releases=fetch(env),checked=versions.catalog(releases,env);
    if(releases==null || index(["invalid_catalog","catalog_too_large"],checked.unavailable_reason)>=0)
        return {success:false,error:"catalog_fetch_failed",entries:cached?map(response(cached,env).entries,(entry)=>({...entry,available:false,reason:"stale_catalog"})):[],cached_at:cached?cached.cached_at:0,stale:!!cached};
    let data={cached_at:now,releases};
    let saved=store(file,data);
    return {...response(data,env),cache_saved:saved};
}
function resolve(id,env,fetch) {
    // Every install obtains fresh metadata. A stale cache is display-only.
    let releases=fetch(env);
    return releases==null?null:versions.resolve(id,releases,env);
}
return {path,load,resolve};
