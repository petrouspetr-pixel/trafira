let fs=require("fs");
const DIRECTORY=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
const LOCK=DIRECTORY+"/operation.lock",OWNER=DIRECTORY+"/operation-owner.json";

function process(pid) {
    if(pid!="self" && !match(""+pid,/^[1-9][0-9]*$/)) return null;
    let raw=fs.readfile("/proc/"+pid+"/stat");
    if(!raw) return null;
    let end=rindex(raw,")"),start=index(raw," ");
    if(end<0 || start<0) return null;
    let fields=split(trim(substr(raw,end+1)),/\s+/);
    return {pid:substr(raw,0,start),parent:fields[1],ticks:fields[19],state:fields[0]};
}

// Only synchronous descendants of the live owner may reuse its operation.
// No CLI flag or environment variable can grant an unrelated worker access.
function owned_by_ancestor() {
    let info=fs.lstat(OWNER);
    if(!info || info.type!="file" || info.size>1024) return false;
    let owner;
    try {owner=json(fs.readfile(OWNER));}catch(e){return false;}
    if(type(owner)!="object") return false;
    let alive=process(owner.pid),current=process("self");
    if(!alive || alive.ticks!=owner.ticks || alive.state=="Z") return false;
    for(let depth=0;current && depth<128;depth++) {
        if(current.pid==owner.pid && current.ticks==owner.ticks) return true;
        if(current.parent=="0" || current.parent==current.pid) break;
        current=process(current.parent);
    }
    return false;
}

function acquire(operation,allow_borrow) {
    let directory=fs.lstat(DIRECTORY);
    if(directory && directory.type!="directory") return null;
    if(!directory && !fs.mkdir(DIRECTORY,448)) return null;
    if(!fs.chmod(DIRECTORY,448)) return null;
    let info=fs.lstat(LOCK);
    if(info && info.type!="file") return null;
    let file=fs.open(LOCK,"ae",384);
    if(!file) return null;
    if(!file.lock("xn")) {
        file.close();
        return allow_borrow!==false && owned_by_ancestor()?{borrowed:true}:null;
    }
    // Stale metadata may remain after SIGKILL. It is replaced only while locked.
    let previous=fs.lstat(OWNER);
    if(previous && previous.type!="file") {file.close();return null;}
    let self=process("self");
    if(!self) {file.close();return null;}
    let metadata=sprintf("%J",{pid:self.pid,ticks:self.ticks});
    let output=fs.open(OWNER,"we",384);
    if(!output) {file.close();return null;}
    let ok=output.write(metadata)==length(metadata);
    output.close();
    if(!ok || !fs.chmod(OWNER,384) || fs.readfile(OWNER)!=metadata) {
        fs.unlink(OWNER);file.close();return null;
    }
    return {file};
}

function release(handle) {
    if(!handle || handle.borrowed || !handle.file) return;
    // Delete metadata before unlocking; never unlink the stable lock inode.
    fs.unlink(OWNER);
    handle.file.close();
    handle.file=null;
}
return {acquire,release};
