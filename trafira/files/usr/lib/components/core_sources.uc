let fs=require("fs"),uci=require("core.uci"),versions=require("components.core_versions");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
const LIMIT=2097152;
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function command(args){return join(" ",map(args,quote));}
function output(args,limit) {
    let p=fs.popen(command(args)+" 2>/dev/null","re");if(!p)return null;
    let text=p.read(limit+1),status=p.close();
    return status==0 && text!=null && length(text)<=limit?trim(text):null;
}
function module_output(path,args) {return output(["ucode","-L",LIB,LIB+"/"+path,...args],4096);}
function transport() {
    let enabled=uci.get("trafira.settings.download_components_via_proxy");
    if(index(["1","true","on","yes"],""+enabled)<0)return {proxy:""};
    let proxy=module_output("singbox/runtime.uc",["service-proxy-address","components"]);
    return proxy && match(proxy,/^([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\]):[0-9]{1,5}$/)?{proxy}:null;
}
function download(url,destination,maximum,timeout) {
    let selected=transport();if(!selected)return false;
    let args=["curl","--connect-timeout","5","--max-time",""+timeout,"--max-filesize",""+maximum,"--proto","=https","--proto-redir","=https","-fsSL"];
    if(selected.proxy)push(args,"--proxy","http://"+selected.proxy,"--noproxy","");
    else push(args,"--noproxy","*");
    push(args,url,"-o",destination);
    // exec makes the ucode timeout refer to curl itself, not an intermediate shell.
    return system("exec "+command(args)+" </dev/null >/dev/null 2>&1",(timeout+5)*1000)==0;
}
function github() {
    let info=fs.lstat(ROOT);
    if(info && info.type!="directory")return null;
    if(!info && !fs.mkdir(ROOT,493))return null;
    let dir=ROOT+sprintf("/core-query-%x-%x",clock()[0],clock()[1]);
    if(!fs.mkdir(dir,448))return null;
    let file=dir+"/response.json",result=null;
    try {
        if(download("https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=100",file,LIMIT,30)) {
            let stat=fs.lstat(file);
            if(stat && stat.type=="file" && stat.size<=LIMIT) {
                let f=fs.open(file,"re"),text=f?f.read(LIMIT+1):null;
                if(f)f.close();
                if(text!=null && length(text)<=LIMIT)result=json(text);
            }
        }
    }catch(e){result=null;}
    fs.unlink(file);fs.rmdir(dir);return result;
}
function environment() {
    let variant=module_output("singbox/runtime.uc",["variant"]);
    let release=getenv("TRAFIRA_OPENWRT_RELEASE")||"/etc/openwrt_release";
    let architecture=module_output("components/updater.uc",["openwrt-release-value",release,"DISTRIB_ARCH"]);
    let apk=system("command -v apk >/dev/null 2>&1")==0;
    let package_type=variant=="extended-compressed"?"tar.gz":apk?"apk":"ipk";
    let binary_architecture=module_output("components/updater.uc",["sing-box-extended-arch-suffix",output(["uname","-m"],256)||"",architecture||""]);
    return {variant,architecture,package_type,binary_architecture};
}
function fetch(env) {
    if(type(env)!="object")return null;
    if(index(["extended","extended-compressed"],env.variant)>=0)return versions.from_github(github(),env);
    if(index(["stable","tiny"],env.variant)<0)return null;
    let name=env.variant=="tiny"?"sing-box-tiny":"sing-box",packages=[];
    if(env.package_type=="apk") {
        let text=output(["apk","query","--from","repositories","--available","--all-matches","--format","json","--fields","name,version,arch",name],LIMIT);
        if(text==null)return null;
        try {packages=json(text);}catch(e){return null;}
    } else if(env.package_type=="ipk") {
        let text=output(["opkg","list",name],LIMIT);if(text==null)return null;
        for(let line in split(text,"\n")) {
            let fields=split(line," - ");
            if(length(fields)>=2 && fields[0]==name)push(packages,{name,version:fields[1],arch:env.architecture});
        }
    } else return null;
    return versions.from_packages(packages,env);
}
function download_repository(candidate,directory) {
    if(!candidate || index(["sing-box","sing-box-tiny"],candidate.repository_package)<0 ||
        type(candidate.version)!="string" || !match(candidate.version,/^[A-Za-z0-9._+~-]{1,128}$/))return null;
    let stat=fs.lstat(directory),selected=transport();
    if(!selected || !stat || stat.type!="directory" || length(fs.lsdir(directory)||[]))return null;
    fs.chmod(directory,448);
    let proxy=selected.proxy?"http://"+selected.proxy:"",bypass=proxy?"":"*";
    let environment=command(["env","http_proxy="+proxy,"HTTP_PROXY="+proxy,"https_proxy="+proxy,"HTTPS_PROXY="+proxy,
        "no_proxy="+bypass,"NO_PROXY="+bypass,"all_proxy=","ALL_PROXY="]);
    let operation;
    if(candidate.package_type=="apk")operation=command(["apk","fetch","--output",directory,candidate.repository_package+"="+candidate.version]);
    else if(candidate.package_type=="ipk")operation=command(["opkg","download",candidate.repository_package]);
    else return null;
    if(system("cd "+quote(directory)+" && exec "+environment+" "+operation+" </dev/null >/dev/null 2>&1",120000)!=0)return null;
    let files=fs.lsdir(directory)||[];
    if(length(files)!=1 || !match(files[0],/^[A-Za-z0-9._+~-]+\.(apk|ipk)$/))return null;
    let path=directory+"/"+files[0];stat=fs.lstat(path);
    // The candidate stage independently verifies package name, architecture and exact revision.
    return stat && stat.type=="file" && stat.size>0 && stat.size<=268435456?path:null;
}
function current_version(){return module_output("singbox/runtime.uc",["version"])||"not-installed";}
return {fetch,environment,transport,download,download_repository,current_version};
