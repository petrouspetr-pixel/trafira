#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib/components"
cat >"$WORK/lib/components/warp_package_runtime.uc" <<'UC'
function execute(action,ctx) {
 assert(ctx.check(["/tmp/new.apk"]) && ctx.install(["/tmp/new.apk"]),"native package commands");
 assert(ctx.remove(["trafira-warp-awg","luci-app-trafira-warp"]),"remove command");
 return {success:true};
}
return {execute};
UC
node - "$ROOT/trafira/files/usr/lib/components/action.uc" "$WORK/test.uc" <<'JS'
const fs=require('fs'),[sourceFile,dest]=process.argv.slice(2),source=fs.readFileSync(sourceFile,'utf8');
const start=source.indexOf('function dispatch_warp('),end=source.indexOf('\nfunction normalize_component_name',start);
fs.writeFileSync(dest,`
let fs=require("fs"),apk=true,tmp_dir="/tmp",TRAFIRA_VERSION="2.1.0",selected_result=null,commands=[];
function is_apk(){return apk;}
function shell_quote(v){return "'"+v+"'";}
function command_from_args(a){return join(" ",map(a,shell_quote));}
function command_success_from_args(a){return true;}
function command_output_from_args(a){return "arch aarch64_cortex-a53 10\\n";}
function write_file(p,t){return true;}
function read_file(p){return "world";}
function read_openwrt_release_value(n){return "aarch64_cortex-a53";}
function installed_package_version(n){return "1.0.0";}
function rollback_archive_info(){return null;}
function filesystem_available_bytes(){return 999999999;}
function mem_available_bytes(){return 999999999;}
function command_success(s){push(commands,s);return true;}
function run_logged_install(message,s){push(commands,s);return true;}
function action_success(){}
function action_fail(){}
${source.slice(start,end)}
for(let kind in [true,false]) {
 apk=kind;commands=[];dispatch_warp("install");
 assert(length(commands)==3,"simulate/install/remove invoked");
 assert(index(commands[0],apk?"--simulate":"--noaction")>=0,"native dependency preflight");
 for(let i=0;i<2;i++) {
  assert(index(commands[i],"PKG_UPGRADE=1")>=0,"postinst start suppressed");
  assert(index(commands[i],apk?"--no-network":"OPKG_CONF_DIR=")>=0,"offline replacement");
  assert(index(commands[i],"/tmp/new.apk")>=0,"exact staged archive");
 }
 if(!apk)assert(index(commands[2],"luci-app-trafira-warp")<index(commands[2],"trafira-warp-awg"),"UI removed before its dependencies");
}
print("WARP native APK/opkg adapter commands passed\\n");
`);
JS
ucode -L "$WORK/lib" "$WORK/test.uc"
