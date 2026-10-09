let fs=require("fs"),hash=require("singbox.provenance").hash_file,storage=require("core.storage");
function failure(error){return {success:false,error};}
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function command(args){return join(" ",map(args,quote));}
function output(args,limit) {
    let pipe=fs.popen(command(args)+" 2>/dev/null","re");if(!pipe)return null;
    let text=pipe.read(limit+1),status=pipe.close();
    return status==0 && text!=null && length(text)<=limit?text:null;
}
function safe_path(value) {
    if(type(value)!="string" || !length(value) || substr(value,0,1)=="/" || !match(value,/^[A-Za-z0-9_.+\/-]+$/))return false;
    for(let part in split(value,"/"))if(part=="..")return false;
    return true;
}
function archive_members(file) {
    let names=output(["tar","-tzf",file],1048576),verbose=output(["tar","-tvzf",file],1048576);
    if(names==null || verbose==null)return null;
    let members=filter(split(names,"\n"),(line)=>length(line)>0),lines=filter(split(verbose,"\n"),(line)=>length(line)>0);
    if(!length(members) || length(members)>4096 || length(members)!=length(lines))return null;
    let expanded=0;
    for(let n=0;n<length(members);n++) {
        if(!safe_path(members[n]) || index(["-","d"],substr(lines[n],0,1))<0)return null;
        let fields=split(trim(lines[n]),/[ \t]+/);
        if(length(fields)<6 || !match(fields[2],/^[0-9]+$/))return null;
        expanded+=int(fields[2],10);
        if(expanded>268435456)return null;
    }
    return {members,expanded};
}
function extract(file,member,destination) {
    if(fs.lstat(destination))return false;
    let stream=fs.open(destination,"wex",384);if(!stream)return false;stream.close();
    return system(command(["tar","-xzf",file,"-O",member])+" >"+quote(destination)+" 2>/dev/null")==0;
}
function binary_version(binary,directory) {
    let result=directory+"/version.txt";
    if(system("exec "+command(["env","LD_LIBRARY_PATH="+directory,binary,"version"])+" >"+quote(result)+" 2>/dev/null",10000)!=0)return "";
    let stat=fs.lstat(result),text=stat && stat.type=="file" && stat.size<=4096?fs.readfile(result):"";
    fs.unlink(result);
    let found=match(text||"",/^sing-box version ([^ \t\r\n]+)/);
    return found?replace(found[1],/\+.*/,""):"";
}
function stage(file,candidate,directory) {
    let info=fs.lstat(file),dir=fs.lstat(directory);
    if(!info || info.type!="file" || info.size<=0 || info.size>268435456 || !dir || dir.type!="directory" || length(fs.lsdir(directory)||[]))return failure("invalid_stage");
    if(!fs.chmod(directory,448))return failure("invalid_stage");
    if(candidate.sha256 && hash(file)!=candidate.sha256)return failure("checksum_mismatch");
    if(candidate.asset_size && candidate.asset_size!=info.size)return failure("artifact_size_mismatch");
    if(candidate.package_type!="tar.gz")return failure("unsupported_package_preflight");
    let listing=archive_members(file);if(!listing)return failure("unsafe_archive");
    if(storage.available_bytes(directory)<listing.expanded+16777216)return failure("insufficient_space");
    let binaries=filter(listing.members,(name)=>match(name,/(^|\/)sing-box$/)),libraries=filter(listing.members,(name)=>match(name,/(^|\/)libcronet\.so$/));
    if(length(binaries)!=1 || length(libraries)>1)return failure("invalid_archive_contents");
    let binary=directory+"/sing-box";
    if(!extract(file,binaries[0],binary) || !fs.chmod(binary,493))return failure("extract_failed");
    if(length(libraries) && !extract(file,libraries[0],directory+"/libcronet.so"))return failure("extract_failed");
    let version=binary_version(binary,directory),expected=replace(candidate.version,/-r[0-9]+$/,"");
    if(!version || version!=expected)return failure("candidate_version_mismatch");
    return {success:true,binary,library_path:directory,version,variant:candidate.variant};
}
return {stage,safe_path};
