#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/trafira/files/usr/lib" -e '
let m=require("integrations.warp_model");
let doc={schema:1,name:"fixture",config:[{".name":"settings",".type":"settings"},{".name":"cfwarp",".type":"section",action:"bypass",user_domains:["example.com"]}]};
let transport={schema:1,owner:"trafira-warp",interface:"tfwarp0",running:true,https_ok:true,warp:true,generation:1};
let result=m.attach(doc,transport,"a","b");
assert(!result.success && result.error=="conflict" && length(doc.config)==2,"stale preview leaves input unchanged");
result=m.attach(doc,transport,"a","a");
assert(result.success && result.section=="cfwarp1" && length(result.document.config)==4,"allocate next free logical section");
let section=filter(result.document.config,(s)=>s[".name"]==result.section)[0];
assert(section.action=="connection" && section.failure_policy=="block","modern connection fails closed");
let child=filter(result.document.config,(s)=>s[".type"]=="section_interface")[0];
assert(child.section==result.section && child.name=="tfwarp0","child references parent and device");
assert(sprintf("%J",doc.config[1])==sprintf("%J",result.document.config[1]),"foreign section unchanged");
let repeated=m.attach(result.document,transport,"a","a");
assert(repeated.success && repeated.changed===false,"idempotent attach");
assert(length(m.references(result.document,"tfwarp0"))==1,"detect references");
let detached=m.detach(result.document,result.section,"a","a");
assert(detached.success && length(detached.document.config)==2,"remove own objects only");
child.name="wan";
assert(!m.detach(result.document,result.section,"a","a").success,"manual binding edit blocks managed removal");
let custom={schema:1,name:"fixture",config:[{".name":"settings",".type":"settings"},{".name":"custom",".type":"section",outbound_json:"{\"type\":\"direct\",\"bind_interface\":\"tfwarp0\"}"}]};
assert(length(m.references(custom,"tfwarp0"))==1,"custom outbound references block transport removal");
print("WARP attach model checks passed\n");
'
