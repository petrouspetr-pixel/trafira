#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let selection=require("components.core_selection");
let current="1.14.2",digest="original",pin_writes=0,fetches=0,stage_error="",check=true,missing=false;
let candidate={version:"1.14.1-r1",variant:"stable",architecture:"aarch64",package_type:"apk",stable:true,repository_package:"sing-box"};
let request={action:"install",candidate_id:"stable~aarch64~apk~1.14.1-r1",expected_current_version:current,pin:true};
let hooks={
 current:()=>current,digest:()=>digest,environment:()=>({variant:"stable",architecture:"aarch64",package_type:"apk"}),
 fetch:()=>{fetches++;return missing?[]:[candidate];},download:()=>"/private/candidate.apk",
 stage:()=>stage_error?{success:false,error:stage_error}:{success:true,binary:"/private/sing-box",library_path:"/private",version:"1.14.1",variant:"stable"},
 check:()=>check,pin_read:()=>null,pin_write:()=>{pin_writes++;return {success:true};},package_version:()=>"1.14.1-r1"
};
current="changed";
assert(selection.prepare(request,hooks).error=="conflict" && fetches==0,"changed installed version rejected before fetch");
current="1.14.2";missing=true;
assert(selection.prepare(request,hooks).error=="candidate_unavailable","deleted release cannot fall back to latest");
missing=false;stage_error="checksum_mismatch";
assert(selection.prepare(request,hooks).error=="checksum_mismatch" && pin_writes==0,"artifact failure keeps pin");
stage_error="";check=false;
assert(selection.prepare(request,hooks).error=="candidate_check_failed" && pin_writes==0,"incompatible older core rejected before pin");
hooks.check=()=>{digest="edited";return true;};
assert(selection.prepare(request,hooks).error=="conflict","configuration edit during preflight rejected");
digest="original";hooks.check=()=>true;
let prepared=selection.prepare(request,hooks);
assert(prepared.success && pin_writes==0,"preparation alone never pins");
assert(selection.finish(prepared,hooks).error=="installed_version_mismatch" && pin_writes==0,"verify actual binary before pin");
current="1.14.1";
assert(selection.finish(prepared,hooks).success && pin_writes==1,"pin only after verified install");
hooks.package_version=()=>"1.14.1-r2";
assert(selection.finish(prepared,hooks).error=="installed_version_mismatch" && pin_writes==1,"exact package revision verified");
print("selected core transaction policy checks passed\n");
'
