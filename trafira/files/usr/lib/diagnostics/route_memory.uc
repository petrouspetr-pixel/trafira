// Independent RSS monitor: virtual-address limits cannot bound Go's resident heap.
let fs=require("fs"),identity=require("service.operation_lock").identity;
const MAX_MEMORY=48*1024*1024,RESERVE=32*1024*1024;
function over_budget(s){return s.rss+s.temporary>MAX_MEMORY || (s.available!=null && s.available<RESERVE);}
function tree(owner,seen){
    let alive=owner?identity(owner.pid):null;
    if(!alive || alive.ticks!=owner.ticks || seen[alive.pid])return [];
    seen[alive.pid]=true;let list=[alive];
    for(let pid in split(trim(fs.readfile("/proc/"+alive.pid+"/task/"+alive.pid+"/children")||""),/\s+/)) {
        let child=identity(pid);if(child && child.parent==alive.pid)for(let item in tree(child,seen))push(list,item);
    }
    return list;
}
function sample(owner,workspace){
    let processes=tree(owner,{}),rss=0,temporary=0;
    for(let item in processes){let value=match(fs.readfile("/proc/"+item.pid+"/status")||"",/VmRSS:[ \t]+([0-9]+)/);if(value)rss+=int(value[1])*1024;}
    for(let name in ["decode-output","cache.stage","cache.stage.meta"]){let info=workspace?fs.lstat(workspace+"/"+name):null;if(info && info.type=="file")temporary+=info.size;}
    let available=match(fs.readfile("/proc/meminfo")||"",/MemAvailable:[ \t]+([0-9]+)/);
    return {rss,temporary,available:available?int(available[1])*1024:null,processes};
}
function stop(processes){
    // Descendants first, with start-time verification to avoid reused PIDs.
    for(let n=length(processes)-1;n>=0;n--){let item=processes[n],alive=identity(item.pid);if(alive && alive.ticks==item.ticks)system("kill -KILL "+alive.pid+" 2>/dev/null");}
}
function read(path){try{return json(fs.readfile(path)||"");}catch(e){return null;}}
function cleanup(dir){
    let saved=read(dir+"/memory-monitor.json"),alive=saved?identity(saved.pid):null;
    if(alive && alive.ticks==saved.ticks)system("kill -KILL "+alive.pid+" 2>/dev/null");
    for(let name in ["memory-monitor.json","memory.error"])fs.unlink(dir+"/"+name);
}
function watch(dir,pid,ticks){
    let owner=identity(pid);if(!owner || owner.ticks!=ticks)return;
    let marker=fs.open(dir+"/memory-monitor.json","wex",384);if(!marker)return;
    marker.write(sprintf("%J",identity()));marker.close();
    for(let i=0;i<1300;i++) {
        let calculator=read(dir+"/calculator.json"),alive=identity(pid),state=read(dir+"/state.json");
        let stats=calculator?sample(owner,dir):null;
        if(!alive || alive.ticks!=ticks || alive.state=="Z" || !state || !state.running){if(calculator)stop(tree(calculator,{}));break;}
        if(stats && over_budget(stats)) {
            let error=fs.open(dir+"/memory.error","wex",384);
            if(error){error.write("resource_limit");error.close();}
            stop(tree(calculator,{}));break;
        }
        system("sleep 0.1");
    }
    fs.unlink(dir+"/memory-monitor.json");
}
if(sourcepath(1)!=null && sourcepath(1)!="")return {over_budget,sample,identity,cleanup};
if(ARGV[0]=="watch" && match(ARGV[1]||"",/^.*\/r-[a-f0-9-]+$/))watch(ARGV[1],ARGV[2],ARGV[3]);
