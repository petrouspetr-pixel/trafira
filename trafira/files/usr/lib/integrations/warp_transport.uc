// SPDX-License-Identifier: GPL-3.0-only
let fs=require("fs"),ip=require("core.ip"),constants=require("core.constants");
const LIB=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
const ADDON=getenv("TRAFIRA_WARP_LIB")||"/usr/lib/trafira-warp";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function valid(status) {
    if(type(status)!="object" || status.schema!=1 || status.owner!="trafira-warp" || status.running!==true || !match(status.interface||"",/^tfwarp[0-9]$/) || status.fwmark!=int(substr(constants.NFT_OUTBOUND_MARK,0,2)=="0x"?substr(constants.NFT_OUTBOUND_MARK,2):constants.NFT_OUTBOUND_MARK,substr(constants.NFT_OUTBOUND_MARK,0,2)=="0x"?16:10))return false;
    let endpoint=match(status.endpoint||"",/^([^:]+):([0-9]+)$/);
    return endpoint && ip.valid_ipv4(endpoint[1]) && int(endpoint[2])>0 && int(endpoint[2])<=65535 && type(status.listen_port)=="int" && status.listen_port>0 && status.listen_port<=65535;
}
function read(probe) {
    if(!fs.stat(ADDON+"/warp/runtime.uc"))return {success:false,error:"component_not_installed",running:false};
    let command=join(" ",map(["ucode","-L",LIB,"-L",ADDON,LIB+"/integrations/warp_cli.uc",probe?"probe":"action",'{"action":"status"}'],quote));
    let pipe=fs.popen("exec "+command+" 2>/dev/null","re");if(!pipe)return {success:false,error:"component_unavailable",running:false};
    let text=pipe.read(16385),code=pipe.close(),status;
    try {if(code==0 && length(text||"")<=16384)status=json(text);}catch(e){}
    if(!valid(status))return {success:false,error:status?.running?"invalid_transport":"transport_stopped",running:false};
    return {success:true,schema:1,owner:"trafira-warp",interface:status.interface,endpoint:status.endpoint,listen_port:status.listen_port,fwmark:status.fwmark,
        running:true,generation:status.generation,https_ok:status.https_ok===true,warp:status.warp===true,handshake_age:status.handshake_age};
}
function exemptions(status) {
    if(!valid(status))return null;
    let endpoint=split(status.endpoint,":");
    // Endpoints are audit data. Router-origin must exempt the verified mark,
    // not all application packets addressed to this endpoint or UDP port.
    return {vpn:[{ip:endpoint[0],port:int(endpoint[1])}],vpn_ports:[status.listen_port],interfaces:[status.interface],fwmark:status.fwmark};
}
return {read,valid,exemptions};
