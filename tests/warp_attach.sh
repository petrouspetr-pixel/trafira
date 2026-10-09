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

# The real generator must bind the owned interface and preserve closed policy/DNS.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WARP_FIXTURE="$WORK/fixture.json"
ucode -L "$ROOT/trafira/files/usr/lib" -e '
let m=require("integrations.warp_model"),format=require("config.profile_format"),fs=require("fs");
let doc={schema:1,name:"fixture",config:[{".name":"settings",".type":"settings",dns_type:"doh",dns_server:"https://1.1.1.1/dns-query",service_listen_address:"127.0.0.1"}]};
let result=m.attach(doc,{schema:1,owner:"trafira-warp",interface:"tfwarp0",running:true,https_ok:true,warp:true},"a","a");
assert(result.success,"attach fixture");
for(let s in result.document.config)if(s[".name"]==result.section)s.user_domains=["example.test"];
fs.writefile(getenv("WARP_FIXTURE"),sprintf("%J",format.fixture(result.document.config)));
'
mkdir -p "$WORK/config.json.section-cache"
ucode -L "$ROOT/trafira/files/usr/lib" "$ROOT/trafira/files/usr/lib/singbox/generator.uc" generate-config-fixture "$WARP_FIXTURE" "$WORK/config.json" 127.0.0.1 0 1 '' 1.14.1
python3 - "$WORK/config.json" <<'PYTEST'
import json,sys
from pathlib import Path
config=json.loads(Path(sys.argv[1]).read_text())
baseline=json.loads(Path(sys.argv[1]+'.failure-policy.json').read_text())
assert any(o.get('bind_interface')=='tfwarp0' for o in baseline['config']['outbounds']),baseline
assert baseline['sections'][0]['failure_policy']=='block'
assert not any(r.get('outbound')=='cfwarp-out' for r in config['route']['rules'])
assert config['dns']['servers'],config
print('WARP real generator binding, DNS and cold fail-closed policy passed')
PYTEST
