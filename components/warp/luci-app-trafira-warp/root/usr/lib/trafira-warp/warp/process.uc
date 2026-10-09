// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),job=require("warp.job");
const EXEC=getenv("TRAFIRA_WARP_EXEC")||"/usr/libexec/trafira-warp-exec";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function run(args,seconds,id) {
    if(type(args)!="array" || !length(args) || type(seconds)!="int" || seconds<1 || seconds>3600 || !job.valid_id(id))return {success:false,error:"invalid_command"};
    for(let arg in args)if(type(arg)!="string" || index(arg,"\u0000")>=0)return {success:false,error:"invalid_command"};
    let command="exec "+join(" ",map([EXEC,""+seconds,state.RUNTIME+"/cancel.json",id,...args],quote))+" 2>/dev/null";
    let pipe=fs.popen(command,"re");if(!pipe)return {success:false,error:"launch_failed"};
    let text=pipe.read(2097153),code=pipe.close();
    if(length(text||"")>2097152)return {success:false,error:"output_limit"};
    return {success:code==0,code,text:text||"",error:code==0?null:job.cancelled(id)?"cancelled":code==124?"timeout":"command_failed"};
}
return {run};
