// SPDX-License-Identifier: GPL-3.0-only
let fs=require("fs"),policy=require("components.warp_packages"),store=require("singbox.failure_store"),sources=require("components.core_sources");
const CACHE=getenv("TRAFIRA_WARP_PACKAGE_CACHE")||"/etc/trafira/warp-packages";
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ADDON=getenv("TRAFIRA_WARP_LIB")||"/usr/lib/trafira-warp";
function fail(error){return {success:false,error};}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function command(args){return join(" ",map(args,quote));}
function run(args){return system("exec "+command(args)+" </dev/null >/dev/null 2>&1",180000)==0;}
function directory(path) {
    let info=fs.lstat(path);return (!info?fs.mkdir(path,448):info.type=="directory") && fs.chmod(path,448);
}
function clear(path) {
    if(substr(path,0,length(CACHE)+1)!=CACHE+"/" || index(path,"..")>=0)return false;
    let info=fs.lstat(path);if(!info)return true;if(info.type!="directory")return false;
    for(let name in fs.lsdir(path)||[]) {
        let child=path+"/"+name,st=fs.lstat(child);
        if(st.type=="directory"){if(!clear(child))return false;}
        else if(st.type!="file" || !fs.unlink(child))return false;
    }
    return fs.rmdir(path);
}
function load(path) {
    let info=fs.lstat(path);if(!info || info.type!="file" || info.size>2097152)return null;
    try {return json(fs.readfile(path));}catch(e){return null;}
}
function family(ctx){return map(policy.NAMES,(name)=>({name,version:ctx.version(name)}));}
function same_family(a,b) {
    if(type(a)!="array" || type(b)!="array" || length(a)!=3 || length(b)!=3)return false;
    for(let item in a)if(length(filter(b,(other)=>other.name==item.name && other.version==item.version))!=1)return false;
    return true;
}
function verify_item(ctx,path,item) {
    let info=ctx.inspect(path,item.name,item.version),stat=fs.lstat(path);
    return info && stat && stat.type=="file" && stat.size==item.size && info.digest==item.sha256 && info.size==item.installed_size;
}
function package_state(action,path) {
    return run(["ucode","-L",LIB,"-L",ADDON,LIB+"/integrations/warp_cli.uc","package-state",action,path]);
}
function fetch_release(ctx) {
    let path=ctx.work+"/release.json";
    return sources.download("https://api.github.com/repos/petrouspetr-pixel/trafira/releases/latest",path,2097152,30)?load(path):null;
}
function fetch_manifest(ctx,release) {
    let asset=policy.release_asset(release,"warp-manifest.json"),path=ctx.work+"/manifest.json";
    if(!asset || !sources.download(asset.url,path,2097152,30))return null;
    return load(path);
}
function stage(ctx,selected,release,dir) {
    if(!directory(dir))return fail("storage_unavailable");
    for(let item in selected.packages) {
        let asset=policy.release_asset(release,item.file),path=dir+"/"+item.file;
        if(!asset || asset.size!=item.size)return {...fail("release_asset_mismatch"),package:item.name};
        if(!sources.download(asset.url,path,item.size,120))return {...fail("package_download_failed"),package:item.name};
        if(!verify_item(ctx,path,item))return {...fail("package_verification_failed"),package:item.name};
    }
    return {...selected,directory:dir};
}
function archive_cache(ctx,selected,from,to) {
    if(!clear(to) || !directory(to))return false;
    for(let item in selected.packages) {
        if(!verify_item(ctx,from+"/"+item.file,item) || !run(["cp",from+"/"+item.file,to+"/"+item.file]) || !verify_item(ctx,to+"/"+item.file,item))return false;
    }
    return store.write(to+"/manifest.json",selected);
}
function previous(ctx) {
    let installed=family(ctx),count=length(filter(installed,(item)=>item.version!=""));
    if(!count)return {packages:[],empty:true};
    if(count!=3)return null;
    let cached=load(CACHE+"/current/manifest.json");
    if(cached && same_family(cached.packages,installed)) {
        for(let item in cached.packages)if(!verify_item(ctx,CACHE+"/current/"+item.file,item))return null;
        return {...cached,directory:CACHE+"/current"};
    }
    // A manually installed family is eligible only when its exact old assets
    // can be downloaded and verified before anything is stopped.
    let ui=filter(installed,(item)=>item.name=="luci-app-trafira-warp")[0],version=match(ui.version,/^([0-9]+\.[0-9]+\.[0-9]+)(-r?[0-9]+)?$/);
    if(!version)return null;
    let path=ctx.work+"/old-release.json";
    if(!sources.download("https://api.github.com/repos/petrouspetr-pixel/trafira/releases/tags/"+version[1],path,2097152,30))return null;
    let release=load(path),manifest=fetch_manifest(ctx,release),selected=policy.select(manifest,ctx.arch,ctx.manager,ctx.trafira_version);
    if(!selected.success || !same_family(selected.packages,installed))return null;
    let staged=stage(ctx,selected,release,ctx.work+"/old");
    return staged.success?staged:null;
}
function install_files(ctx,selected) {
    if(selected.empty) {
        let installed=filter(policy.NAMES,(name)=>ctx.version(name)!="");
        return !length(installed) || ctx.remove(installed);
    }
    for(let item in selected.packages)if(!verify_item(ctx,selected.directory+"/"+item.file,item))return false;
    return ctx.install(map(selected.packages,(item)=>selected.directory+"/"+item.file));
}
function recover(ctx) {
    let path=CACHE+"/journal.json",info=fs.lstat(path);if(!info)return {success:true,restored:false};
    let journal=load(path);if(!journal || journal.schema!=1 || !journal.previous)return fail("recovery_error");
    let old=journal.previous;
    if(old.empty!==true && old.directory!=CACHE+"/rollback")return fail("recovery_error");
    // Interrupted replacement may have removed the init script. Reinstalling
    // the staged old family must still be possible; a present script must stop.
    if(fs.stat("/etc/init.d/trafira-warp") && !run(["/etc/init.d/trafira-warp","stop"]))return fail("recovery_error");
    if(!install_files(ctx,old))return fail("recovery_error");
    if(!old.empty && (!same_family(family(ctx),old.packages) || !package_state("restore",CACHE+"/rollback/state.json") || !archive_cache(ctx,old,CACHE+"/rollback",CACHE+"/current")))return fail("recovery_error");
    if(old.empty && !clear(CACHE+"/current"))return fail("recovery_error");
    if(journal.world!=null && !ctx.restore_world(journal.world))return fail("recovery_error");
    if(!fs.unlink(path) || system("sync")!=0)return fail("recovery_error");
    return {success:true,restored:true};
}
function execute(action,ctx) {
    if(index(["install","check_update","remove","recover"],action)<0)return fail("invalid_action");
    if(action=="recover")return recover(ctx);
    if(ctx.arch!="aarch64_cortex-a53")return fail("unsupported_platform");
    if(action!="check_update") {
        if(!directory(CACHE))return fail("storage_unavailable");
        let recovered=recover(ctx);if(!recovered.success)return {...recovered,rollback_error:true};
    }
    let release=action=="remove"?null:fetch_release(ctx),manifest=release?fetch_manifest(ctx,release):null;
    let selected=policy.select(manifest,ctx.arch,ctx.manager,ctx.trafira_version),current=ctx.version("luci-app-trafira-warp");
    if(action=="check_update")return selected.success?{success:true,status:same_family(selected.packages,family(ctx))?"latest":"outdated",current_version:current,latest_version:selected.family_version,release_url:"https://github.com/petrouspetr-pixel/trafira/releases/tag/"+release.tag_name}: {success:true,status:"unavailable",current_version:current,reason:selected.error};
    if(action!="remove" && !selected.success)return selected;
    if(action=="remove") {
        let config=load("/etc/trafira-warp/transport.json");
        if(config && length(require("integrations.warp_model").references({config:require("integrations.warp_attach").references()},config.interface)))return fail("references_exist");
    }
    let old=null;
    let hooks={
        stage:()=>{
            if(action=="remove")return {empty:true,packages:[]};
            let bytes=0;for(let item in selected.packages)bytes+=item.size+item.installed_size;
            if(!ctx.space(bytes*2+8388608,bytes+8388608))return fail("insufficient_space");
            let staged=stage(ctx,selected,release,ctx.work+"/new");
            if(!staged.success)return staged;
            return ctx.check(map(staged.packages,(item)=>staged.directory+"/"+item.file))?staged:fail("dependency_check_failed");
        },
        stage_previous:()=>previous(ctx),
        snapshot:()=>{
            if(!current)return {running:false,enabled:false};
            if(!package_state("snapshot",ctx.work+"/state.json"))return null;
            return load(ctx.work+"/state.json");
        },
        space:(next,prev)=>{
            let bytes=0;for(let item in [...next.packages,...prev.packages])bytes+=item.size+item.installed_size;
            return ctx.space(bytes+8388608,bytes+8388608);
        },
        journal:(original,prev,next)=>{
            old=prev;
            if(prev.empty){if(!clear(CACHE+"/rollback") || !directory(CACHE+"/rollback"))return false;}
            else if(!archive_cache(ctx,prev,prev.directory,CACHE+"/rollback") || !run(["cp",ctx.work+"/state.json",CACHE+"/rollback/state.json"]))return false;
            if(!prev.empty)old={...prev,directory:CACHE+"/rollback"};
            return store.write(CACHE+"/journal.json",{schema:1,previous:old,world:ctx.world()}) && system("sync")==0;
        },
        stop:()=>{
            if(!current)return true;
            if(action=="remove" && !package_state("remove",ctx.work+"/state.json"))return false;
            return run(["/etc/init.d/trafira-warp","stop"]);
        },
        install:(next)=>install_files(ctx,next),
        verify:(next)=>next.empty?length(filter(family(ctx),(item)=>item.version!=""))==0:same_family(family(ctx),next.packages),
        resume:()=>action=="remove" || !current || package_state("resume",ctx.work+"/state.json"),
        commit:(next)=>next.empty?clear(CACHE+"/current"):archive_cache(ctx,next,next.directory,CACHE+"/current"),
        restore:()=>recover(ctx).success,
        clear:()=>!fs.lstat(CACHE+"/journal.json") || (fs.unlink(CACHE+"/journal.json") && system("sync")==0)
    };
    let result=policy.install(action=="remove"?{success:true}:selected,hooks);
    if(result.success || result.restored){clear(CACHE+"/rollback");clear(CACHE+"/next");}
    return {...result,current_version:ctx.version("luci-app-trafira-warp"),latest_version:action=="remove"?"":selected.family_version,changed:result.success?1:0,status:result.success?(action=="remove"?"":"latest"):""};
}
return {execute,recover};
