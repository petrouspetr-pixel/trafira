let fs=require("fs"),profiles=require("config.profiles");
const DIRECTORY=(getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira")+"/profile-transfers";
const LIMIT=1048576,CHUNK=12288;
function fail(error){return {success:false,error};}
function valid(id,kind){return type(id)=="string" && match(id,/^[ie]-[a-f0-9-]{1,60}$/) && substr(id,0,1)==kind;}
function path(id){return DIRECTORY+"/"+id;}
function ensure(){
    let info=fs.lstat(DIRECTORY);
    if(info && info.type!="directory")return false;
    if(!info && !fs.mkdir(DIRECTORY,448))return false;
    return fs.chmod(DIRECTORY,448);
}
function info(id,kind){
    if(!valid(id,kind))return null;
    let stat=fs.lstat(path(id));
    return stat && stat.type=="file" && stat.size<=LIMIT && clock()[0]-stat.mtime<900?stat:null;
}
function begin(kind,content){
    if(!ensure())return fail("storage_unavailable");
    let count=0;
    for(let name in fs.lsdir(DIRECTORY)||[]) {
        if(!valid(name,"i") && !valid(name,"e"))continue;
        let stat=fs.lstat(path(name));
        if(stat && stat.type=="file" && clock()[0]-stat.mtime>=900)fs.unlink(path(name));
        else count++;
    }
    if(count>=4)return fail("transfer_limit");
    if(length(content)>LIMIT)return fail("profile_too_large");
    let id=sprintf("%s-%x-%x",kind,clock()[0],clock()[1]),file=fs.open(path(id),"wex",384);
    if(!file)return fail("storage_unavailable");
    let ok=file.write(content)==length(content);file.close();
    if(!ok || fs.readfile(path(id))!=content){fs.unlink(path(id));return fail("storage_unavailable");}
    return {success:true,id,bytes:length(content),chunk_bytes:CHUNK};
}
function append(id,offset,data){
    let stat=info(id,"i");
    if(!stat || type(offset)!="int" || offset!=stat.size)return fail("transfer_conflict");
    if(type(data)!="string" || !length(data) || length(data)>16384 || !match(data,/^[A-Za-z0-9+\/]*={0,2}$/))return fail("invalid_chunk");
    let decoded=b64dec(data);
    if(decoded==null || b64enc(decoded)!=data || stat.size+length(decoded)>LIMIT)return fail("profile_too_large");
    let file=fs.open(path(id),"ae",384);if(!file)return fail("storage_unavailable");
    let ok=file.write(decoded)==length(decoded);file.close();
    let text=fs.readfile(path(id));
    if(!ok || length(text)!=offset+length(decoded) || substr(text,offset)!=decoded)return fail("storage_unavailable");
    return {success:true,offset:length(text)};
}
function finish(id){
    if(!info(id,"i"))return fail("invalid_transfer");
    let document;
    try {document=json(fs.readfile(path(id)));}catch(e){return fail("invalid_profile");}
    let result=profiles.create(document);
    if(result.success)fs.unlink(path(id));
    return result;
}
function export_begin(id){
    let result=profiles.export_profile(id);
    return result.success?begin("e",sprintf("%J",result.document)):result;
}
function read(id,offset){
    let stat=info(id,"e");
    if(!stat || type(offset)!="int" || offset<0 || offset>stat.size)return fail("invalid_transfer");
    let file=fs.open(path(id),"re");if(!file)return fail("storage_unavailable");
    file.seek(offset);
    let data=file.read(CHUNK);file.close();
    if(data==null && offset<stat.size)return fail("read_failed");
    data=data||"";
    return {success:true,data:b64enc(data),offset:offset+length(data),done:offset+length(data)>=stat.size};
}
function cancel(id){
    if(!valid(id,"i") && !valid(id,"e"))return fail("invalid_transfer");
    let stat=fs.lstat(path(id));
    return stat && stat.type=="file" && fs.unlink(path(id))?{success:true}:fail("invalid_transfer");
}
return {begin,append,finish,export_begin,read,cancel};
