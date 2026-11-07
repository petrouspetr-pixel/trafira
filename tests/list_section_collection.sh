#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/updates.uc" "$WORK_DIR/check.uc" <<'JS'
const fs=require('fs'),[sourcePath,target]=process.argv.slice(2),source=fs.readFileSync(sourcePath,'utf8');
const names=['list_reference_label','domain_ip_list_ruleset_path','reset_domain_ip_list_ruleset',
 'collect_section_nft_input','stage_section_list_publication','add_plain_subnet_file_to_nft_for_section','add_json_ruleset_subnets_to_nft_for_section',
 'import_domain_ip_list_file_into_rulesets','import_domain_ip_list_reference_into_rulesets','rebuild_domain_ip_lists_from_rule',
 'import_builtin_subnets_from_rule','import_custom_ruleset_subnets_from_local','import_custom_ruleset_subnets_from_remote',
 'import_rule_sets_with_subnets_from_rule','run_list_update_stage','finish_section_nft_collection','update_section_subnet_lists'];
const code=names.map(name=>{const start=source.indexOf(`function ${name}(`);if(start<0)throw Error(name);return {start,body:source.slice(start,source.indexOf('\n}',start)+2)};}).sort((a,b)=>a.start-b.start).map(x=>x.body).join('\n');
fs.writeFileSync(target,`
let fs=require("fs"),routing=require("routing.rulesets"),community=require("routing.community"),ip=require("core.ip");
let TMP_RULESET_FOLDER=ARGV[0],LIB_DIR="fixture",RELOAD_LOCK_DIR="reload",NFT_TABLE_NAME="Fixture";
let NFT_COMMON_SET_NAME="v4",NFT_COMMON6_SET_NAME="v6",NFT_IP_PORT_SET_NAME="p4",NFT_IP_PORT6_SET_NAME="p6";
let NFT_INTERFACE_SET_NAME="if",NFT_DISCORD_SET_NAME="d4",NFT_DISCORD6_SET_NAME="d6",NFT_FAKEIP_MARK="mark";
let section_nft_collection=null,counter=0,downloads=[],applies=0,kernel="old-kernel",last_inputs=[],fail_download=false,kernel_status=0,locked=false,messages=[],generation=21;
function check(ok,message){if(!ok)die(message+"\\n");}
function as_string(value){return value==null?"":""+value;}
function section_name(section){return section[".name"];}
function bool_option(section,key,fallback){return section[key]==null?fallback:section[key]!="0";}
function option(section,key,fallback){return section[key]==null?fallback:section[key];}
function list_option_values(section,key){return section[key]||[];}
function temp_path(){let path=TMP_RULESET_FOLDER+"/temp-"+(++counter);fs.writefile(path,"");return path;}
function file_exists_value(path){return fs.stat(path)!=null;}
function file_nonempty(path){let s=fs.stat(path);return s && s.size>0;}
function write_file(path,text){return fs.writefile(path,text)!=null;}
function json_text(value){return sprintf("%J\\n",value);}
function copy_file(a,b){let text=fs.readfile(a);return text!=null && write_file(b,text);}
function remove_file(path){fs.unlink(path);}
function remove_files(paths){for(let path in paths)if(path!="")fs.unlink(path);}
function ensure_dir(path){return true;}
function owner_pid(){return "123";}
function log_message(text,level){push(messages,text);}
function routing_rulesets_module(){return routing;}
function community_subnets_module(){return community;}
function singbox_rulesets_module(){return require("singbox.rulesets");}
function service_proxy_address(settings,purpose){return "";}
function convert_crlf_to_lf(path){return true;}
function acquire_runtime_lock(path,wait){check(!locked,"nested reload lock");locked=true;return true;}
function release_runtime_lock(path){locked=false;}
let connections={community_lists:function(section){return section.community_lists||[];},rule_sets_with_subnets:function(section){return section.rule_set_with_subnets||[];}};
function command_success_from_args(args){
 if(args[0]=="cmp")return fs.readfile(args[2])==fs.readfile(args[3]);
 if(args[0]=="sing-box"){return write_file(args[5],'{"version":3,"rules":[{"ip_cidr":["198.51.100.40"],"port":[443]}]}');}
 return false;
}
function ruleset_module_success(args){
 if(args[0]=="create-source"){routing.create_source(args[1]);return true;}
 if(args[0]=="import-plain-list"){routing.import_plain_list(args[1],args[2],args[3],args[4],args[5],"","");return true;}
 return false;
}
function nft_module_success(args){
 check(args[0]=="split-domain-subnet-file","nft was changed before the complete section was collected");
 let domains=[],subnets=[];
 for(let value in split(trim(fs.readfile(args[1])),"\\n"))if(ip.valid_ip_or_cidr(value))push(subnets,value);else push(domains,value);
 return write_file(args[2],join("\\n",domains)+"\\n") && write_file(args[3],join("\\n",subnets)+"\\n");
}
function download_to_file(url,path,proxy,label){
 push(downloads,url);
 if(url=="https://fixture/custom.json")return !fail_download && write_file(path,'{"version":3,"rules":[{"ip_cidr":["198.51.100.30"],"port":[443]}]}');
 if(index(url,"IPv6")>=0)return write_file(path,"2001:db8::21\\n");
 if(index(url,"IPv4")>=0)return write_file(path,"198.51.100."+generation+"\\n");
 return write_file(path,"fresh.example\\n198.51.100.10\\n");
}
function module_status(args){
 check(args[1]=="nft-replace-section-subnets-for-uci-section" && locked,"replacement must hold the reload lock");
 applies++;last_inputs=[];
 let manifest=json(fs.readfile(args[3]));check(manifest.section[".name"]=="vpn","manifest needs the prepared section generation");
 for(let input in manifest.inputs){let text=fs.readfile(input.path);check(text!=null,"importer deleted its collected contribution");push(last_inputs,{kind:input.kind,text});}
 if(kernel_status==0)kernel=sprintf("%J",last_inputs);
 return kernel_status;
}
`+code+`
let local=TMP_RULESET_FOLDER+"/local.json";
write_file(local,'{"version":3,"rules":[{"ip_cidr":["198.51.100.50"],"port_range":["1000:1002"]}]}');
let section={".name":"vpn",enabled:"1",action:"proxy",domain_ip_lists:["https://fixture/domain.txt"],community_lists:["twitter"],rule_set_with_subnets:[local,"https://fixture/custom.json"]};
let path=domain_ip_list_ruleset_path(section),old='{"version":3,"rules":[{"domain_suffix":["old.example"]},{"ip_cidr":["198.51.100.99"]}]}';
write_file(TMP_RULESET_FOLDER+"/community-twitter-ipv4.json",'{"version":3,"rules":[{"ip_cidr":["198.51.100.20"]}]}');
write_file(path,old);
check(update_section_subnet_lists(section,{}),"complete section collection failed");
check(applies==1 && !locked && section_nft_collection==null,"one complete section commit and released state");
check(index(fs.readfile(path),"fresh.example")>=0 && index(fs.readfile(path),"old.example")<0,"JSON was not replaced");
let aggregate=sprintf("%J",last_inputs);
for(let address in ["198.51.100.10","198.51.100.20","198.51.100.21","2001:db8::21","198.51.100.30","198.51.100.50"])
 check(index(aggregate,address)>=0,"lost section contributor "+address);
check(length(downloads)==4,"aggregation downloaded an input twice");
check(index(aggregate,'port_range')>=0 && index(aggregate,'443')>=0,"custom JSON port scopes were discarded");
write_file(path,old);let before=kernel;applies=0;fail_download=true;generation=22;
let community_path=TMP_RULESET_FOLDER+"/community-twitter-ipv4.json",community_before=fs.readfile(community_path);
check(!update_section_subnet_lists(section,{}),"failure in the last configured source must fail the section");
check(applies==0 && fs.readfile(path)==old && kernel==before,"late source failure changed JSON or nft");
check(fs.readfile(community_path)==community_before,"late source failure published community JSON");
fail_download=false;kernel_status=1;applies=0;
check(!update_section_subnet_lists(section,{}),"kernel rejection must fail the section");
check(applies==1 && fs.readfile(path)==old && kernel==before,"kernel rejection did not restore old JSON/kernel");
check(fs.readfile(community_path)==community_before,"kernel rejection did not roll back community JSON");
fs.unlink(path);applies=0;
check(!update_section_subnet_lists(section,{}) && !file_exists_value(path),"failed first commit left a new JSON behind");
kernel_status=2;applies=0;
check(update_section_subnet_lists(section,{}) && file_exists_value(path),"absent startup table must keep materialized JSON");
for(let name in fs.lsdir(TMP_RULESET_FOLDER))
 check(index(name,"temp-")!=0 && index(name,".stage.")<0,"section collection left a temporary/recovery file: "+name);
print("Section collection keeps all contributors, never redownloads, and restores JSON on late failures\\n");
`);
JS
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/check.uc" "$WORK_DIR"
