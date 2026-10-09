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
function binary_version(binary,directory,library_path) {
    let result=directory+"/version.txt";
    if(system("exec "+command(["env","LD_LIBRARY_PATH="+(library_path||directory),binary,"version"])+" >"+quote(result)+" 2>/dev/null",10000)!=0)return "";
    let stat=fs.lstat(result),text=stat && stat.type=="file" && stat.size<=4096?fs.readfile(result):"";
    fs.unlink(result);
    let found=match(text||"",/^sing-box version ([^ \t\r\n]+)/);
    return found?replace(found[1],/\+.*/,""):"";
}
function finish(binary,library_path,candidate,directory) {
    if(!fs.chmod(binary,493))return failure("extract_failed");
    let version=binary_version(binary,directory,library_path),expected=replace(candidate.version,/-r[0-9]+$/,"");
    if(candidate.repository_package && candidate.package_type=="ipk")expected=replace(expected,/-[0-9]+$/,"");
    if(!version || version!=expected)return failure("candidate_version_mismatch");
    return {success:true,binary,library_path,version,variant:candidate.variant};
}
function stage_tar(file,candidate,directory) {
    let listing=archive_members(file);if(!listing)return failure("unsafe_archive");
    if(storage.available_bytes(directory)<listing.expanded+16777216)return failure("insufficient_space");
    let binaries=filter(listing.members,(name)=>match(name,/(^|\/)sing-box$/)),libraries=filter(listing.members,(name)=>match(name,/(^|\/)libcronet\.so$/));
    if(length(binaries)!=1 || length(libraries)>1)return failure("invalid_archive_contents");
    let binary=directory+"/sing-box";
    if(!extract(file,binaries[0],binary) || !fs.chmod(binary,493))return failure("extract_failed");
    if(length(libraries) && !extract(file,libraries[0],directory+"/libcronet.so"))return failure("extract_failed");
    return finish(binary,directory,candidate,directory);
}
function field(text,key) {
    for(let line in split(text||"","\n")) {
        line=trim(line);
        if(substr(line,0,length(key)+1)==key+":")return trim(substr(line,length(key)+1));
    }
    return "";
}
function package_matches(name,version,arch,candidate) {
    let expected=candidate.variant=="tiny"?"sing-box-tiny":candidate.variant=="extended"?"sing-box-extended":"sing-box";
    if(name!=expected || arch!=candidate.architecture)return false;
    return version==candidate.version || (candidate.variant=="extended" && replace(version,/(-r[0-9]+|-[0-9]+)$/,"")==candidate.version);
}
function stage_ipk(file,candidate,directory) {
    let outer=archive_members(file);if(!outer)return failure("unsafe_archive");
    let controls=filter(outer.members,(name)=>match(name,/(^|\/)control\.tar\.gz$/)),data=filter(outer.members,(name)=>match(name,/(^|\/)data\.tar\.gz$/));
    if(length(controls)!=1 || length(data)!=1)return failure("unsupported_package_preflight");
    if(storage.available_bytes(directory)<outer.expanded+16777216)return failure("insufficient_space");
    let control_file=directory+"/control.tar.gz",data_file=directory+"/data.tar.gz";
    if(!extract(file,controls[0],control_file))return failure("extract_failed");
    let listing=archive_members(control_file);if(!listing)return failure("unsafe_archive");
    let names=filter(listing.members,(name)=>match(name,/(^|\/)control$/));
    if(length(names)!=1)return failure("invalid_package_metadata");
    let text=output(["tar","-xzOf",control_file,names[0]],65536);
    if(!package_matches(field(text,"Package"),field(text,"Version"),field(text,"Architecture"),candidate))return failure("package_metadata_mismatch");
    if(!extract(file,data[0],data_file))return failure("extract_failed");
    let result=stage_tar(data_file,candidate,directory);
    fs.unlink(control_file);fs.unlink(data_file);return result;
}
function stage_apk(file,candidate,directory) {
    let text=output(["apk","--allow-untrusted","adbdump",file],2097152);
    if(text==null)return failure("unsupported_package_preflight");
    if(!package_matches(field(text,"name"),field(text,"version"),field(text,"arch"),candidate))return failure("package_metadata_mismatch");
    // Reject non-canonical names and links before the package tool sees a destination.
    for(let line in split(text,"\n")) {
        line=trim(line);
        if(match(line,/^(target|link-target|rdev):/))return failure("unsafe_archive");
        line=replace(line,/^-[ \t]+/,"");
        if(substr(line,0,5)=="name:") {
            let name=trim(substr(line,5));
            if(name && !safe_path(name))return failure("unsafe_archive");
        }
    }
    let size=field(text,"installed-size");
    if(!match(size,/^[0-9]+$/) || int(size)<=0 || int(size)>268435456)return failure("invalid_package_metadata");
    if(storage.available_bytes(directory)<int(size)+16777216)return failure("insufficient_space");
    let root=directory+"/payload";
    if(!fs.mkdir(root,448) || system(command(["apk","--allow-untrusted","extract","--no-chown","--destination",root,file])+" >/dev/null 2>&1")!=0)return failure("extract_failed");
    let binary=root+"/usr/bin/sing-box",library_path=root+"/usr/lib",stat=fs.lstat(binary),resolved=fs.realpath(binary),prefix=fs.realpath(root)+"/";
    if(!stat || stat.type!="file" || !resolved || substr(resolved,0,length(prefix))!=prefix)return failure("unsafe_archive");
    if(!fs.lstat(library_path) && !fs.mkdir(library_path,448))return failure("extract_failed");
    let libraries=fs.lstat(library_path),library_real=fs.realpath(library_path);
    if(!libraries || libraries.type!="directory" || !library_real || substr(library_real,0,length(prefix))!=prefix)return failure("unsafe_archive");
    return finish(binary,library_path,candidate,directory);
}
function stage(file,candidate,directory) {
    let info=fs.lstat(file),dir=fs.lstat(directory);
    if(!info || info.type!="file" || info.size<=0 || info.size>268435456 || !dir || dir.type!="directory" || length(fs.lsdir(directory)||[]))return failure("invalid_stage");
    if(!fs.chmod(directory,448))return failure("invalid_stage");
    if(candidate.sha256 && hash(file)!=candidate.sha256)return failure("checksum_mismatch");
    if(candidate.asset_size && candidate.asset_size!=info.size)return failure("artifact_size_mismatch");
    if(candidate.package_type=="tar.gz")return stage_tar(file,candidate,directory);
    if(candidate.package_type=="ipk")return stage_ipk(file,candidate,directory);
    if(candidate.package_type=="apk")return stage_apk(file,candidate,directory);
    return failure("unsupported_package_preflight");
}
return {stage,safe_path};
