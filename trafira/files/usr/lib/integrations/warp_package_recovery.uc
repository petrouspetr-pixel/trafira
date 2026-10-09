// SPDX-License-Identifier: GPL-3.0-only
let fs=require("fs");
function quote(value){return "'"+replace(value,/'/g,"'\\''")+"'";}
function before_start() {
 let cache=getenv("TRAFIRA_WARP_PACKAGE_CACHE")||"/etc/trafira/warp-packages";
 if(!fs.lstat(cache+"/journal.json"))return true;
 let lib=getenv("TRAFIRA_LIB")||"/usr/lib/trafira";
 // Synchronous child borrows only the live startup coordinator's lock.
 return system("ucode -L "+quote(lib)+" "+quote(lib+"/components/action.uc")+" component-action warp recover </dev/null >/dev/null 2>&1",180000)==0;
}
return {before_start};
