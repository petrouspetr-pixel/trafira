#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_CONFIG_FILE="$WORK_DIR/uci" ROUTE_NATIVE_TEST="$WORK_DIR"
export REAL_UCODE="$(command -v ucode)"
if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then REAL_SING_BOX=$(command -v sing-box); export REAL_SING_BOX; fi
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR" "$TRAFIRA_RULESET_CACHE_DIR"
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in *service/state.uc*sing-box-service-running*) exit 0;; esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nprintf network >"$ROUTE_NATIVE_TEST/network"\nexit 91\n' >"$WORK_DIR/bin/curl"
printf '#!/bin/sh\nprintf "203.0.113.1\\n203.0.113.2\\n203.0.113.3\\n203.0.113.4\\n"\n' >"$WORK_DIR/bin/dig"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
if [ "$2" = match ]; then
 printf 'native\n' >>"$ROUTE_NATIVE_TEST/native-calls"
 [ ! -f "$ROUTE_NATIVE_TEST/no-native" ] || exit 1
 if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then exec "$REAL_SING_BOX" "$@"; fi
 node - "$5" "$6" <<'JS'
const fs=require('fs'),c=JSON.parse(fs.readFileSync(process.argv[2])),d=process.argv[3];
if(c.rules.some(r=>(r.domain_suffix||[]).some(s=>d===s||d.endsWith('.'+s))))console.log('match rules.[0]: domain_suffix');
JS
else
 printf 'decode\n' >>"$ROUTE_NATIVE_TEST/decode-calls"
 if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then exec "$REAL_SING_BOX" "$@"; fi
 cp "$3" "$5"
fi
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/setup.uc" <<'UC'
let fs=require("fs"),cache=require("singbox.ruleset_cache"),root=getenv("ROUTE_NATIVE_TEST");
let sets=[{tag:"ads",type:"remote",format:"binary",url:"https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs"},
{tag:"youtube",type:"remote",format:"binary",url:"https://github.com/itdoginfo/allow-domains/releases/latest/download/youtube.srs"},
{tag:"mixed",type:"local",format:"source",path:root+"/mixed.json"}];
for(let rule in sets){
 let path=rule.type=="remote"?cache.path(rule):rule.path;
 let data={version:3,rules:[rule.tag=="mixed"?{ip_cidr:["192.0.2.128/25"]}:{domain_suffix:[rule.tag=="youtube"?"youtube.com":"advert.example"]}]};
 fs.writefile(path,sprintf("%J",data));
 if(getenv("TRAFIRA_REAL_CODEC")=="1" && rule.type=="remote"){
  fs.writefile(root+"/source.json",sprintf("%J",data));
  assert(system(getenv("REAL_SING_BOX")+" rule-set compile "+root+"/source.json -o "+path)==0,"compile real fixture");
 }
 if(rule.tag=="youtube")fs.writefile(root+"/youtube-path",path);
}
fs.writefile(root+"/config.json",sprintf("%J",{inbounds:[{tag:"dns-health-active-main-in",listen:"127.0.0.42",listen_port:12053}],
dns:{strategy:"ipv4_only",servers:[]},outbounds:[],route:{rule_set:sets,rules:[{rule_set:"ads",action:"reject"},
{rule_set:"youtube",source_ip_cidr:["192.0.2.0/24"],port:443,outbound:"zapret2-out"},{rule_set:"mixed",outbound:"awg-out"}],final:"direct-out"}}));
UC
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/setup.uc"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$WORK_DIR/uci"
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config");assert(a.save(a.capture(require("core.uci").get_all("trafira","settings"),[])));'
check(){
 ucode -L "$TRAFIRA_LIB" -e '
 let r=require("diagnostics.route_analysis").explain(sprintf("%J",{domain:"youtube.com",source:{kind:"device",ip:ARGV[0]},port:int(ARGV[1]),network:"tcp",protocol:"tls"}),{background:true,workspace:ARGV[3]});
 assert(r.success && r.decision.outbound==ARGV[2],sprintf("%J",r));
 assert(length(r.destinations)==4 && r.rule_sets.unavailable==0,"all four destination addresses are checked without losing lists");
 ' "$1" "$2" "$3" "$WORK_DIR"
}
check 192.0.2.5 443 zapret2-out
test "$(wc -l <"$WORK_DIR/native-calls")" = 2
test ! -e "$WORK_DIR/decode-calls"
check 198.51.100.5 443 direct-out
test "$(wc -l <"$WORK_DIR/native-calls")" = 2
test "$(wc -l <"$WORK_DIR/decode-calls")" = 1
check 192.0.2.5 80 direct-out
test "$(wc -l <"$WORK_DIR/native-calls")" = 2
test "$(wc -l <"$WORK_DIR/decode-calls")" = 2
# An old core without the native command still uses the full interpreter.
touch "$WORK_DIR/no-native"
printf '\n# replaced core\n' >>"$WORK_DIR/bin/sing-box"
check 192.0.2.5 443 zapret2-out
test "$(wc -l <"$WORK_DIR/decode-calls")" = 4
test ! -e "$WORK_DIR/network"
printf 'native domain cold/warm/multi-IP/source/port/legacy-core checks passed\n'
