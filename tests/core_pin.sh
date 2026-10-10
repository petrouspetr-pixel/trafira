#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.keep=original\n' >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let p=require("components.core_pin"),uci=require("core.uci");
assert(p.read()==null,"no implicit pin");
assert(!p.write({version:"https://attacker.invalid",variant:"stable"}).success,"invalid version rejected");
assert(p.write({version:"1.14.1-r1",variant:"stable"}).success,"pin saved");
assert(p.read().version=="1.14.1-r1" && uci.get("trafira.settings.keep")=="original","pin scoped to two fields");
let commit=uci.commit,attempts=0;
uci.commit=function(name){attempts++;return attempts==1?false:commit(name);};
let failed=p.write({version:"1.14.2-r1",variant:"stable"});
uci.commit=commit;
assert(!failed.success && failed.restored && p.read().version=="1.14.1-r1","failed commit restores previous pin");
assert(p.write(null).success && p.read()==null,"unpin");
let current="1.14.2",variant="stable",revision="1.14.2-r3",writes=0;
let hooks={current:function(){return current;},environment:function(){return {variant};},
    installed_version:function(){return revision;},write:function(value){writes++;return p.write(value);}};
let request={action:"pin",expected_current_version:current,expected_current_variant:variant};
assert(p.request_valid(request),"explicit installed pin request");
assert(!p.request_valid({...request,candidate_id:"not-used"}),"pin rejects candidate override");
assert(!p.request_valid({...request,expected_current_variant:"unknown"}),"invalid variant rejected");
let result=p.pin_installed(request,hooks);
assert(result.success && result.pin.version==revision && p.read().version==revision,"pin stores exact installed package revision without installation");
assert(p.read().variant=="stable" && writes==1,"pin persists installed variant");
current="1.14.3";
assert(p.pin_installed(request,hooks).error=="conflict" && writes==1,"changed current version does not write");
current="1.14.2";variant="tiny";
assert(p.pin_installed(request,hooks).error=="conflict" && writes==1,"changed variant does not write");
variant="stable";revision="";
assert(!p.pin_installed(request,hooks).success && writes==1,"missing installed package metadata does not guess a pin");
current="not-installed";request.expected_current_version=current;
assert(!p.pin_installed(request,hooks).success && writes==1,"absent core cannot be pinned");
assert(p.write(null).success && p.read()==null,"explicit pin can be unpinned persistently");
assert(p.request_valid({action:"install",candidate_id:"stable~aarch64~apk~1.14.1-r1",pin:true,expected_current_version:"1.14.2"}),"bounded version request");
assert(!p.request_valid({action:"install",candidate_id:"https://attacker.invalid",pin:true,expected_current_version:"1.14.2"}),"caller URL rejected");
assert(!p.request_valid({action:"install",candidate_id:"valid",pin:true,expected_current_version:"1.14.2",asset_url:"https://attacker.invalid"}),"unknown request field rejected");
assert(!p.request_valid({action:"install",candidate_id:"valid",pin:"yes",expected_current_version:"1.14.2"}),"pin boolean required");
let fs=require("fs"),sources=require("components.core_sources"),original_popen=fs.popen,commands=[];
fs.popen=function(command,mode){
    push(commands,command);
    let output=index(command,"core/packages.uc")>=0?"1.14.2-r3\n":"1.14.2-extended-2.7.2+build\n";
    return {read:()=>output,close:()=>0};
};
assert(sources.installed_version({variant:"stable"})=="1.14.2-r3","stable pins package revision");
assert(sources.installed_version({variant:"tiny"})=="1.14.2-r3" && index(commands[1],"sing-box-tiny")>=0,"tiny queries its own package");
assert(sources.installed_version({variant:"extended"})=="1.14.2-extended-2.7.2","extended pin follows release identifier");
assert(sources.installed_version({variant:"extended-compressed"})=="1.14.2-extended-2.7.2","compressed pin follows binary release");
assert(sources.installed_version({variant:"unknown"})=="","unknown variant has no guessed pin");
fs.popen=original_popen;
print("core pin persistence checks passed\n");
'
