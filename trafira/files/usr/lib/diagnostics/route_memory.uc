// Independent RSS monitor: virtual-address limits cannot bound Go's resident heap.
let fs=require("fs"),identity=require("service.operation_lock").identity;
const MAX_MEMORY=48*1024*1024,RESERVE=64*1024*1024;
function memory_budget(total){return total>0?min(128*1024*1024,int(total/4)):MAX_MEMORY;}
function over_budget(s){return s.unsupported===true || (s.private_rss!=null?s.private_rss:s.rss)+s.temporary>(s.budget||MAX_MEMORY) || (s.available!=null && s.available<RESERVE);}
function tree(owner,seen){
    let alive=owner?identity(owner.pid):null;
    if(!alive || alive.ticks!=owner.ticks || seen[alive.pid])return [];
    seen[alive.pid]=true;let list=[alive];
    let children=fs.readfile("/proc/"+alive.pid+"/task/"+alive.pid+"/children");
    if(children==null){
        // OpenWrt kernels often omit CONFIG_CHECKPOINT_RESTORE and its children
        // file. Fall back to PPID from stat, retaining start-time verification.
        let entries=fs.lsdir("/proc");
        if(entries==null){let again=identity(alive.pid);if(again && again.ticks==alive.ticks && again.state!="Z")seen.unavailable=true;return list;}
        let pids=[];
        for(let name in entries)if(match(name,/^[1-9][0-9]*$/)) {
            let child=identity(name);if(child && child.parent==alive.pid)push(pids,name);
        }
        children=join(" ",pids);
    }
    for(let pid in split(trim(children),/\s+/)) {
        let child=identity(pid);if(child && child.parent==alive.pid)for(let item in tree(child,seen))push(list,item);
    }
    return list;
}
function sample(owner,workspace,extra){
    let seen={},processes=tree(owner,seen),rss=0,private_rss=0,temporary=0;
    for(let additional in extra||[])for(let item in tree(additional,seen))push(processes,item);
    for(let item in processes){
        let status=fs.readfile("/proc/"+item.pid+"/status")||"",value=match(status,/VmRSS:[ \t]+([0-9]+)/),anonymous=match(status,/RssAnon:[ \t]+([0-9]+)/),shared=match(status,/RssShmem:[ \t]+([0-9]+)/);
        if(value){rss+=int(value[1])*1024;private_rss+=(anonymous && shared?int(anonymous[1])+int(shared[1]):int(value[1]))*1024;}
    }
    for(let name in ["decode-output","cache.stage","cache.stage.meta"]){let info=workspace?fs.lstat(workspace+"/"+name):null;if(info && info.type=="file")temporary+=info.size;}
    let meminfo=fs.readfile("/proc/meminfo")||"",total=match(meminfo,/MemTotal:[ \t]+([0-9]+)/);
    let available=match(meminfo,/MemAvailable:[ \t]+([0-9]+)/);
    return {rss,private_rss,temporary,budget:memory_budget(total?int(total[1])*1024:0),unsupported:seen.unavailable===true,available:available?int(available[1])*1024:null,processes};
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
        let stats=calculator?sample(calculator,dir,[owner,identity()]):null;
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
if(ARGV[0]=="watch" && match(ARGV[1]||"",/^.*\/r-[a-f0-9-]+$/)){watch(ARGV[1],ARGV[2],ARGV[3]);exit(0);}
return {over_budget,sample,identity,cleanup,stop,tree,memory_budget};
