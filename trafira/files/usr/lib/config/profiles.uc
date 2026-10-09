let fs=require("fs");
let format=require("config.profile_format");
const DIRECTORY=getenv("TRAFIRA_PROFILES_DIR")||"/etc/trafira/profiles";
const MAX_FILE=1048576,MAX_TOTAL=8388608,MAX_COUNT=8;
let serial=0;
function failure(error) { return {success:false,error}; }
function valid_id(id) { return type(id)=="string" && match(id,/^p-[a-z0-9-]{1,60}$/)!=null; }
function ensure() {
    let parent=substr(DIRECTORY,0,rindex(DIRECTORY,"/"));
    if(!fs.stat(parent)) fs.mkdir(parent,448);
    let info=fs.lstat(DIRECTORY);
    if(info && info.type!="directory") return false;
    if(!info && !fs.mkdir(DIRECTORY,448)) return false;
    return fs.chmod(DIRECTORY,448);
}
function locked(callback) {
    if(!ensure()) return failure("storage_unavailable");
    let lock=fs.open(DIRECTORY+"/.lock","ae",384);
    if(!lock) return failure("storage_unavailable");
    if(!lock.lock("xn")) {lock.close();return failure("busy");}
    let result;
    try { result=callback(); } catch(e) { result=failure("storage_error"); }
    lock.close();return result;
}
function path(id) {return DIRECTORY+"/"+id+".json";}
function ids() {
    return map(filter(fs.lsdir(DIRECTORY)||[],(name)=>match(name,/^p-[a-z0-9-]{1,60}[.]json$/)),(name)=>substr(name,0,-5));
}
function read(id) {
    if(!valid_id(id)) return null;
    let file=path(id),info=fs.lstat(file);
    if(!info || info.type!="file" || info.size>MAX_FILE) return null;
    let handle=fs.open(file,"r"); if(!handle) return null;
    let raw=handle.read(MAX_FILE+1);handle.close();
    if(length(raw||"")>MAX_FILE) return null;
    try {let doc=json(raw);return format.validate(doc).valid?doc:null;}catch(e){return null;}
}
function write(id,document) {
    let text=sprintf("%J",document);
    if(length(text)>MAX_FILE) return failure("profile_too_large");
    let total=0;
    for(let other in ids()) {
        let info=fs.lstat(path(other));
        if(info && info.type=="file" && other!=id) total+=info.size;
    }
    if(total+length(text)>MAX_TOTAL) return failure("quota_exceeded");
    let existing=fs.lstat(path(id));
    if(existing && existing.type!="file") return failure("invalid_profile_file");
    let temporary=path(id)+".stage";
    if(fs.lstat(temporary)) return failure("staging_conflict");
    let file=fs.open(temporary,"we",384);
    if(!file) return failure("storage_full_or_unavailable");
    let ok=file.write(text)==length(text);
    if(!file.flush()) ok=false;
    file.close();
    if(!fs.chmod(temporary,384)) ok=false;
    if(ok) ok=fs.rename(temporary,path(id));
    if(!ok) {fs.unlink(temporary);return failure("storage_full_or_unavailable");}
    return {success:true,id};
}
function create(document) {
    return locked(function() {
        let validation=format.validate(document);
        if(!validation.valid) return {success:false,error:"invalid_profile",errors:validation.errors};
        if(length(ids())>=MAX_COUNT) return failure("profile_limit");
        let stamp=clock();
        let id=sprintf("p-%x-%x-%x",time(),stamp[1],++serial);
        if(fs.lstat(path(id))) return failure("id_conflict");
        let copy=json(sprintf("%J",document));
        copy.created_at=copy.created_at||time();
        return write(id,copy);
    });
}
function list() {
    return locked(function() {
        let entries=[],total=0;
        for(let id in ids()) {
            let info=fs.lstat(path(id)),doc=read(id);
            if(info && info.type=="file") total+=info.size;
            if(doc) push(entries,{id,name:doc.name,created_at:doc.created_at,bytes:info.size});
            else push(entries,{id,name:id,invalid:true,bytes:info?info.size:0});
        }
        return {success:true,entries,total_bytes:total,max_count:MAX_COUNT,max_file_bytes:MAX_FILE,quota_bytes:MAX_TOTAL};
    });
}
function export_profile(id) {
    return locked(function() {let doc=read(id);return doc?{success:true,document:doc}:failure("profile_unavailable");});
}
function rename(id,name) {
    return locked(function() {
        if(!format.name_valid(name)) return failure("invalid_name");
        let doc=read(id);if(!doc) return failure("profile_unavailable");
        doc.name=name;return write(id,doc);
    });
}
function remove(id) {
    return locked(function() {
        if(!valid_id(id)) return failure("invalid_id");
        let info=fs.lstat(path(id));
        if(!info || info.type!="file") return failure("profile_unavailable");
        return fs.unlink(path(id))?{success:true}:failure("remove_failed");
    });
}
function preview(id,current) {
    return locked(function() {
        let doc=read(id);if(!doc) return failure("profile_unavailable");
        return {success:true,name:doc.name,changes:format.diff(current,doc.config)};
    });
}
return {DIRECTORY,MAX_FILE,valid_id,create,list,export_profile,rename,remove,preview};
