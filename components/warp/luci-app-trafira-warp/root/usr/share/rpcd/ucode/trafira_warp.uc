// SPDX-License-Identifier: Apache-2.0
let fs=require("fs");
const CLI=getenv("TRAFIRA_WARP_CLI")||"/usr/bin/trafira-config";
function clean(value,depth) {
    if(type(value)!="object" || depth>2)return {success:false,error:"invalid_response"};
    let out={success:value.success!==false};
    for(let key in ["running","enabled","registered","restored","recovery_pending","rollback_error","https_ok","warp","removal"])
        if(type(value[key])=="bool")out[key]=value[key];
    for(let key in ["job_id","candidate_id","preview_id","expected_digest","section","error","stage","interface","owner"])
        if(type(value[key])=="string" && match(value[key],/^[a-zA-Z0-9_-]{1,96}$/))out[key]=value[key];
    for(let key in ["schema","generation","handshake_age","checked_at","started_at","completed_at","expires_at","samples","transport_errors","http_restricted","median","p95"])
        if(index(["int","double"],type(value[key]))>=0 && value[key]>=0)out[key]=value[key];
    if(type(value.endpoint)=="string" && match(value.endpoint,/^[0-9.]+:[0-9]{1,5}$/))out.endpoint=value.endpoint;
    for(let key in ["job","candidate","test","summary"])if(type(value[key])=="object")out[key]=clean(value[key],depth+1);
    if(type(value.changes)=="array")out.changes=map(slice(value.changes,0,256),(change)=>{
        let v={};if(type(change)!="object")return v;
        if(type(change.section)=="string" && match(change.section,/^[a-zA-Z0-9_]{1,96}$/))v.section=change.section;
        if(index(["added","removed","changed"],change.change)>=0)v.change=change.change;
        return v;
    });
    return out;
}
function run(text,write) {
    if(type(text)!="string" || length(text)>16384)return {success:false,error:"invalid_request"};
    let request;try {request=json(text);}catch(e){return {success:false,error:"invalid_request"};}
    if(type(request)!="object" || type(request.action)!="string")return {success:false,error:"invalid_request"};
    if(!write && index(["status","job_status"],request.action)<0)return {success:false,error:"permission_denied"};
    if(write && index(["register","enable","disable","reconnect","preview_attach","attach","preview_detach","detach","unregister","scan_start","scan_apply","test_start","cancel"],request.action)<0)return {success:false,error:"invalid_request"};
    let pipe=fs.popen("exec '"+replace(CLI,/'/g,"'\\''")+"' warp_action '"+replace(text,/'/g,"'\\''")+"' 2>/dev/null","re");
    if(!pipe)return {success:false,error:"component_unavailable"};
    let output=pipe.read(65537),code=pipe.close(),value;
    try {if(code==0 && length(output||"")<=65536)value=json(output);}catch(e){}
    return type(value)=="object"?clean(value,0):{success:false,error:"invalid_response"};
}
return {"luci.trafira_warp":{
    status:{call:()=>run('{"action":"status"}',false)},
    job_status:{call:()=>run('{"action":"job_status"}',false)},
    action:{args:{request:""},call:(request)=>run(request.args.request,true)}
}};
