#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/trafira/files/usr/lib" -e '
let p=require("components.warp_packages");
let digest=join(map([1,2,3,4,5,6,7,8],()=>"aaaaaaaa"),"");
let packages=map(["luci-app-trafira-warp","trafira-warp-awg","trafira-warp-scout"],(name)=>({name,version:"1.0.0-r1",arch:"aarch64_cortex-a53",manager:"apk",file:name+"-1.0.0-r1.apk",sha256:digest,installed_size:1000,size:500}));
let manifest={schema:1,family_version:"1.0.0",minimum_trafira_version:"2.0.0",packages};
let selected=p.select(manifest,"aarch64_cortex-a53","apk","2.1.0");assert(selected.success,"valid complete family");
assert(!p.select(manifest,"mips","apk","2.1.0").success,"unsupported architecture before mutation");
assert(!p.select({...manifest,packages:slice(packages,0,2)},"aarch64_cortex-a53","apk","2.1.0").success,"missing package rejected");
assert(!p.select(manifest,"aarch64_cortex-a53","apk","1.0.0").success,"minimum Trafira required");
let calls=[],old={packages,enabled:false,running:false};
let hooks={stage:()=>null,stage_previous:()=>old,snapshot:()=>({enabled:false,running:false}),stop:()=>{push(calls,"stop");return true;},install:()=>{push(calls,"install");return true;},verify:()=>true,restore:()=>{push(calls,"restore");return true;},commit:()=>true,resume:(state)=>{push(calls,state.running?"start":"keep_stopped");return true;}};
assert(!p.install(selected,hooks).success && !length(calls),"invalid SHA/metadata stage fails before stop");
hooks.stage=()=>({packages});hooks.stage_previous=()=>null;
assert(!p.install(selected,hooks).success && !length(calls),"missing rollback archive fails before stop");
hooks.stage_previous=()=>old;hooks.install=()=>{push(calls,"partial_install");return false;};
let failed=p.install(selected,hooks);assert(!failed.success && failed.restored && index(calls,"restore")>=0,"partial install rolls back complete family");
calls=[];hooks.install=()=>true;
assert(p.install(selected,hooks).success && index(calls,"keep_stopped")>=0 && index(calls,"start")<0,"disabled service remains stopped");
assert(!p.release_asset({tag_name:"v1",assets:[{name:"manifest.json",browser_download_url:"https://evil.invalid/file"}]},"manifest.json"),"own release source only");
print("WARP package family preflight and rollback checks passed\n");
'
