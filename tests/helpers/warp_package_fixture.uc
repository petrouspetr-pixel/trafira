let fs=require("fs"),runtime=require("components.warp_package_runtime"),policy=require("components.warp_packages");
let root=getenv("FIXTURE"),assets=root+"/assets",cache=getenv("TRAFIRA_WARP_PACKAGE_CACHE"),installed={},failed=false,rollback_fail=false,space=true,simulated=true;
fs.mkdir(assets,448);
function digest(path){let f=fs.popen("sha256sum '"+path+"'","r"),s=f.read("all");f.close();return split(s," ")[0];}
function manifest(manager,version) {
 let packages=[];
 for(let name in policy.NAMES) {
  let file=name+"-"+version+(manager=="apk"?".apk":".ipk"),text=name+":"+version;
  fs.writefile(assets+"/"+file,text);
  push(packages,{name,version,arch:"aarch64_cortex-a53",manager,file,size:length(text),installed_size:length(text),sha256:digest(assets+"/"+file)});
 }
 let m={schema:1,family_version:version,minimum_trafira_version:"2.0.0",packages};
 fs.writefile(assets+"/warp-manifest.json",sprintf("%J",m));
 let list=[];for(let name in ["warp-manifest.json",...map(packages,(p)=>p.file)])push(list,{name,size:fs.stat(assets+"/"+name).size,browser_download_url:"https://github.com/petrouspetr-pixel/trafira/releases/download/"+version+"/"+name});
 fs.writefile(assets+"/release.json",sprintf("%J",{tag_name:version,assets:list}));return m;
}
let ctx={work:root+"/work",manager:"apk",arch:"aarch64_cortex-a53",trafira_version:"2.1.0",
 version:(name)=>installed[name]||"",inspect:(path,name,version)=>{
  let text=fs.readfile(path);return text==name+":"+version?{digest:digest(path),size:length(text)}:null;
 },space:()=>space,check:()=>simulated,
 install:(files)=>{
  for(let path in files){let fields=split(fs.readfile(path),":");installed[fields[0]]=fields[1];
   if(failed && fields[1]=="2.0.0"){fs.writefile(root+"/offline","");return false;}
   if(rollback_fail)return false;
  }return true;
 },remove:(names)=>{for(let name in names)delete installed[name];return true;},world:()=>"original-world",restore_world:(v)=>v=="original-world"};
for(let manager in ["apk","opkg"]) {
 ctx.manager=manager;installed={};fs.unlink(root+"/offline");manifest(manager,"1.0.0");
 let first=runtime.execute("install",ctx);assert(first.success,sprintf("first install %J",first));
 assert(!fs.stat(root+"/service.calls"),"first install remains inactive");
 fs.unlink(root+"/state-operation");manifest(manager,"2.0.0");space=false;
 assert(!runtime.execute("install",ctx).success && !fs.stat(root+"/service.calls"),"space failure never stops old family");
 space=true;simulated=false;assert(!runtime.execute("install",ctx).success && !fs.stat(root+"/service.calls"),"dependency preflight never stops old family");simulated=true;
 failed=true;let result=runtime.execute("install",ctx);
 assert(!result.success && result.restored && !result.rollback_error,sprintf("offline rollback %J",result));
 for(let name in policy.NAMES)assert(installed[name]=="1.0.0","all old packages restored");
 assert(fs.readfile(root+"/state-operation")=="restore","runtime restored");
 assert(!fs.stat(cache+"/journal.json"),"successful recovery clears journal");
 fs.unlink(root+"/offline");rollback_fail=true;result=runtime.execute("install",ctx);
 assert(result.rollback_error && fs.stat(cache+"/journal.json"),"failed recovery retains complete durable journal");
 rollback_fail=false;failed=false;assert(runtime.execute("recover",ctx).success,"next process recovers offline");
 for(let name in policy.NAMES)assert(installed[name]=="1.0.0","exact family after recovery");
 fs.unlink(root+"/offline");result=runtime.execute("install",ctx);assert(result.success,sprintf("upgrade %J",result));
 assert(fs.readfile(root+"/state-operation")=="resume","original service state supplied on success");
 fs.unlink(root+"/service.calls");
}
print("WARP package runtime: both formats, preflight, partial install, offline recovery and stopped-state passed\n");
