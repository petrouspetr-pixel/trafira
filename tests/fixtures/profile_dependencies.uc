let inspector=require("config.profile_dependencies");
let visits=[],components=[];
let hooks={
    file:(path)=>{push(visits,path);return path=="/etc/cert.pem"?"present":"missing";},
    component:(name)=>{push(components,name);return {available:name!="zapret2",version:name=="sing_box"?"1.14.3":"",variant:"standard"};}
};
let doc={schema:1,name:"private-profile-name",config:[
    {".name":"settings",".type":"settings",dns_mtls_enabled:"1",dns_mtls_client_certificate:"/etc/cert.pem",dns_mtls_client_key:"/etc/key.pem",secret:"DO_NOT_LEAK"},
    {".name":"private_section_name",".type":"section",action:"zapret2",enabled:"1",rule_set:["/etc/custom.srs","https://secret-token@example.com/list.srs"],subscription_url:["https://private-token@example.com/sub"]},
    {".name":"off",".type":"server",enabled:"0",tls_key_path:"/etc/optional.pem"},
    {".name":"json",".type":"section",action:"connection",selector_proxy_links:["vless://SECRET_UUID@example.com:443?security=tls&type=xhttp"],outbound_jsons:["{\"type\":\"vless\",\"password\":\"SECRET_JSON\",\"tls\":{\"client_key_path\":\"/etc/json-key.pem\"}}"]}
]};
let before=sprintf("%J",doc),result=inspector.inspect(doc,hooks);
assert(result.success && result.report.schema==1,"report schema");
assert(sprintf("%J",doc)==before,"profile is immutable");
assert(result.report.counts.section==2 && result.report.counts.server==1,"section counts");
assert(length(result.report.files)==5,"all external paths found, URLs omitted");
let files={};for(let file in result.report.files)files[file.path]=file;
assert(files["/etc/cert.pem"].status=="present","existing certificate");
assert(files["/etc/key.pem"].status=="missing" && files["/etc/key.pem"].required,"required private key missing");
assert(!files["/etc/optional.pem"].required,"disabled server dependency is optional");
let core=null;for(let component in result.report.components)if(component.id=="sing_box")core=component;
assert(core && core.status=="incompatible" && core.requirement=="extended","XHTTP requirement detected");
assert(index(components,"zapret2")>=0,"DPI component checked");
let text=sprintf("%J",result);
for(let secret in ["DO_NOT_LEAK","SECRET_UUID","SECRET_JSON","secret-token","private-token","private-profile-name","private_section_name","https://"])
    assert(index(text,secret)<0,"report privacy: "+secret);
assert(index(result.report.warnings,"custom_json_review")>=0,"custom JSON is not certified");
let bad=json(before);bad.config[3].outbound_jsons=["{broken"];
result=inspector.inspect(bad,hooks);
assert(result.success && index(result.report.warnings,"invalid_custom_json")>=0,"invalid JSON warning without raw content");
let limited=json(before);limited.config[1].rule_set=[];
for(let i=0;i<100;i++)push(limited.config[1].rule_set,"/etc/custom-"+i+".srs");
result=inspector.inspect(limited,hooks);
assert(result.success && result.report.limited && length(result.report.files)<=64,"bounded dependency list");
let invalid={schema:1,name:"Bad",config:[{".name":"settings",".type":"settings",tls_key_path:"relative/SECRET_VALUE"}]};
result=inspector.inspect(invalid,hooks);
assert(index(sprintf("%J",result),"SECRET_VALUE")<0,"invalid paths are redacted");
assert(index(result.report.warnings,"invalid_path")>=0,"invalid path warning");
let scalar=json(before);scalar.config[1].rule_set="https://secret-token@example.com/a.srs /etc/scalar-a.srs /etc/scalar-b.srs";
result=inspector.inspect(scalar,hooks);
let paths=map(result.report.files,item=>item.path);
assert(index(paths,"/etc/scalar-a.srs")>=0 && index(paths,"/etc/scalar-b.srs")>=0,"scalar rule sets use runtime whitespace normalization");
assert(index(sprintf("%J",result),"secret-token")<0,"scalar list URL is private");
let empty={schema:1,name:"Empty",config:[{".name":"settings",".type":"settings"},{".name":"demo",".type":"section",action:"connection",outbound_json:""}]};
result=inspector.inspect(empty,hooks);
assert(index(result.report.warnings,"invalid_custom_json")<0,"empty optional JSON is not an error");
let shadow=json(before);
shadow.config[3].outbound_json="{\"type\":\"vless\",\"tls\":{\"client_key_path\":\"/etc/old-json.pem\"}}";
shadow.config[3].outbound_jsons=["{\"type\":\"direct\"}"];
result=inspector.inspect(shadow,hooks);
assert(!filter(result.report.files,item=>item.path=="/etc/old-json.pem")[0].required,"shadowed legacy JSON is optional");
delete shadow.config[3].outbound_jsons;
result=inspector.inspect(shadow,hooks);
assert(filter(result.report.files,item=>item.path=="/etc/old-json.pem")[0].required,"legacy JSON is required when effective");
for(let test in [["vless","reality",false],["socks","tls",false],["trojan","",true],["hysteria2","none",true],["vmess","none",false]]) {
    let server=json(before);
    push(server.config,{".name":"servercase",".type":"server",enabled:"1",protocol:test[0],security:test[1],tls_key_path:"/etc/server-key.pem"});
    result=inspector.inspect(server,hooks);
    assert(filter(result.report.files,item=>item.path=="/etc/server-key.pem")[0].required===test[2],"native TLS policy mirrors server generator: "+test[0]);
}
let disabled=json(before);
disabled.config[3].outbound_jsons=["{\"type\":\"vless\",\"tls\":{\"enabled\":false,\"client_key_path\":\"/etc/disabled-tls.pem\"}}"];
result=inspector.inspect(disabled,hooks);
assert(!filter(result.report.files,item=>item.path=="/etc/disabled-tls.pem")[0].required,"disabled JSON TLS is optional");
let scalar_links=json(before);
scalar_links.config[3].selector_proxy_links="socks5://first.example:1080 vless://SECRET_UUID@second.example:443?security=tls&type=xhttp";
result=inspector.inspect(scalar_links,hooks);
assert(filter(result.report.components,item=>item.id=="sing_box")[0].requirement=="extended","scalar connection links use runtime normalization");
let controls={schema:1,name:"Controls",config:[{".name":"settings",".type":"settings",tls_key_path:"/etc/SECRET_VALUE\n.pem"}]};
result=inspector.inspect(controls,hooks);
assert(index(sprintf("%J",result),"SECRET_VALUE")<0 && index(result.report.warnings,"invalid_path")>=0,"control characters in paths are rejected without regex evaluation");
print("profile dependency inspector checks passed\n");
