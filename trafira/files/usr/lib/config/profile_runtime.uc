let fs=require("fs"),format=require("config.profile_format"),constants=require("core.constants");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const INIT=getenv("TRAFIRA_SERVICE_INIT")||"/etc/init.d/trafira";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function command(args){return join(" ",map(args,quote));}
function run(args){return system(command(args)+" >/dev/null 2>&1")==0;}
function module_args(path,args){return ["ucode","-L",LIB,LIB+"/"+path,...args];}
function output(args){
    let p=fs.popen(command(args)+" 2>/dev/null","re");if(!p)return "";
    let text=p.read(4096),status=p.close();return status==0?trim(text||""):"";
}
function private_write(path,text){
    let info=fs.lstat(path);if(info && info.type!="file")return false;
    let f=fs.open(path,"we",384);if(!f)return false;
    let ok=f.write(text)==length(text);f.close();
    return ok && fs.chmod(path,384) && fs.readfile(path)==text;
}
function dependencies(value){
    if(type(value)=="array") {
        for(let child in value)if(!dependencies(child))return false;
    } else if(type(value)=="object") {
        for(let key,child in value) {
            if(index(["certificate_path","key_path","client_certificate_path","client_key_path"],key)>=0 && child) {
                if(type(child)!="string")return false;
                let info=fs.stat(child);if(!info || info.type!="file")return false;
                let f=fs.open(child,"re");if(!f)return false;f.close();
            }
            if(key=="bind_interface" && child) {
                if(type(child)!="string" || !match(child,/^[A-Za-z0-9_.:-]{1,15}$/) || !fs.stat("/sys/class/net/"+child))return false;
            }
            if(!dependencies(child))return false;
        }
    }
    return true;
}
function prepare(document,directory){
    let validation=format.validate(document);
    if(!validation.valid)return {success:false,error:"invalid_profile",errors:validation.errors};
    let info=fs.lstat(directory);
    if(info && info.type!="directory")return {success:false,error:"invalid_staging_directory"};
    if(!info && !fs.mkdir(directory,448))return {success:false,error:"storage_unavailable"};
    if(!fs.chmod(directory,448) || !private_write(directory+"/trafira",format.to_uci(document.config)))return {success:false,error:"storage_unavailable"};
    return {success:true,path:directory+"/trafira"};
}
function validate(document,directory,path){
    if(!format.validate(document).valid || fs.readfile(path)!=format.to_uci(document.config))return false;
    let fixture=format.fixture(document.config),fixture_path=directory+"/fixture.json",generated=directory+"/sing-box.json";
    if(!private_write(fixture_path,sprintf("%J",fixture)))return false;
    if(!run(module_args("config/validator.uc",["validate-runtime-fixture",fixture_path,"{}"])))return false;
    let version=output(module_args("singbox/runtime.uc",["version"]));
    if(!version)return false;
    let variant=output(module_args("singbox/runtime.uc",["variant"]));
    let address=fixture.settings.service_listen_address||output(module_args("singbox/runtime.uc",["service-listen-address"]));
    if(!address)return false;
    if(!run(module_args("singbox/generator.uc",["generate-config-fixture",fixture_path,generated,address,"0",index(variant,"extended")>=0?"1":"0","",version])))return false;
    let config;
    try {config=json(fs.readfile(generated));}catch(e){return false;}
    if(!dependencies(config))return false;
    // Check is read-only; it must never start an alternate runtime.
    return run(["sing-box","-c",generated,"check"]);
}
function running(){return run(module_args("service/state.uc",["trafira-running",constants.RT_TABLE_NAME,constants.NFT_TABLE_NAME,constants.NFT_FAKEIP_MARK]));}
function capture(){return {running:running(),enabled:run([INIT,"enabled"])};}
function activate(state){return run([INIT,"restart"]) && running();}
function restore(state){
    if(type(state)!="object")return false;
    // No apply step changes the autostart symlinks.
    if(state.running)return run([INIT,"restart"]) && running();
    return run([INIT,"stop"]) && !running();
}
function hooks(document,directory){
    return {validate:(path)=>validate(document,directory,path),capture,activate,restore};
}
function read_document(path,directory,name){
    let info=fs.lstat(path);
    if(!info || info.type!="file" || info.size>1048576)return {success:false,error:"invalid_config_file"};
    let f=fs.open(path,"re");if(!f)return {success:false,error:"invalid_config_file"};
    let text=f.read(1048577);f.close();
    if(text==null || length(text)>1048576)return {success:false,error:"invalid_config_file"};
    let isolated=directory+"/read",saved=isolated+"/saved";
    if(!fs.mkdir(isolated,448))return {success:false,error:"storage_unavailable"};
    if(!fs.mkdir(saved,448) || !private_write(isolated+"/trafira",text))return {success:false,error:"storage_unavailable"};
    let document={schema:1,name,config:[]};
    try {
        let cursor=require("uci").cursor(isolated,saved);
        if(!cursor.load("trafira"))return {success:false,error:"invalid_config_file"};
        for(let kind in format.TYPES)cursor.foreach("trafira",kind,function(section){push(document.config,section);});
        cursor.unload("trafira");
        sort(document.config,(a,b)=>int(a[".index"]||0)-int(b[".index"]||0));
    }catch(e){return {success:false,error:"invalid_config_file"};}
    let validation=format.validate(document);
    return validation.valid?{success:true,document}:{success:false,error:"invalid_profile",errors:validation.errors};
}
return {prepare,hooks,dependencies,read_document};
