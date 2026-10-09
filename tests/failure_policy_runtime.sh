#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR" FAILURE_RUNTIME_TEST="$WORK_DIR"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_LIB="$WORK_DIR/lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/lib/service"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
if [ "$1" = -f ]; then printf 'guard\n' >>"$FAILURE_RUNTIME_TEST/events"; exit 0; fi
if [ "$1" = delete ]; then printf 'unguard\n' >>"$FAILURE_RUNTIME_TEST/events"; exit 0; fi
exit 0
SH
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
printf 'check\n' >>"$FAILURE_RUNTIME_TEST/events"
exit 0
SH
cat >"$WORK_DIR/lib/service/state.uc" <<'UC'
let fs=require("fs"),root=getenv("FAILURE_RUNTIME_TEST");
if(ARGV[0]=="sing-box-service-runtime-pid") {print("123\n");exit(0);}
let f=fs.open(root+"/events","a");f.write(ARGV[0]+"\n");f.close();
exit(ARGV[0]=="wait-trafira-stable-start" && fs.stat(root+"/fail-health")?1:0);
UC
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),store=require("singbox.failure_store"),a=require("service.failure_policy_apply"),transform=require("singbox.failure_config");
let root=getenv("FAILURE_RUNTIME_TEST"),path=root+"/config.json",sections=[{".name":"vpn",action:"connection",failure_policy:"block"}];
let base={inbounds:[{tag:"protected",type:"mixed",listen_port:18000}],outbounds:[{type:"direct",tag:"vpn-out"}],route:{rules:[{action:"route",inbound:"protected",outbound:"vpn-out"}]},dns:{servers:[],rules:[]}};
assert(store.write(path,transform.apply(base,sections,{})) && store.save_base(path,base,sections));
let generation=store.load(path).generation;
assert(a.apply("vpn",generation,"primary").success,"actual adapter applies checked config");
assert(json(fs.readfile(path)).route.rules[0].outbound=="vpn-out","primary installed");
let events=fs.readfile(root+"/events");
assert(index(events,"guard\n")<index(events,"reload-sing-box-runtime") && index(events,"wait-trafira-stable-start")<index(events,"unguard\n"),"real command ordering");
fs.writefile(root+"/fail-health","1");fs.writefile(root+"/events","");
let result=a.apply("vpn",generation,"blocked");
assert(!result.success && result.guarded && index(fs.readfile(root+"/events"),"unguard\n")<0,"failed restart retains guard");
assert(json(fs.readfile(path)).route.rules[0].outbound=="vpn-out","exact previous config restored behind guard");
print("failure policy runtime adapter checks passed\n");
'
rm -f "$WORK_DIR/fail-health"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
target=
kind=delay
for arg in "$@"; do case "$arg" in */proxies) kind=proxies;; esac; done
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; target=$1; fi
  shift
done
if [ "$kind" = proxies ]; then printf '%s' '{"proxies":{"vpn-out":{"now":"node"},"node":{"type":"Socks"}}}' >"$target"
else printf '%s' '{"delay":10}' >"$target"; fi
SH
chmod +x "$WORK_DIR/bin/curl"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let s=require("singbox.failure_store"),t=require("singbox.failure_config"),path=getenv("FAILURE_RUNTIME_TEST")+"/config.json";
let base=s.load(path);base.config.experimental={clash_api:{external_controller:"127.0.0.1:9090"}};
assert(s.write(path,t.apply(base.config,base.sections,{})) && s.save_base(path,base.config,base.sections));
'
for round in 1 2; do
  ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/trafira/files/usr/lib/singbox/priority.uc" failure-policy-tick
done
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let s=require("singbox.failure_store"),base=s.load(getenv("FAILURE_RUNTIME_TEST")+"/config.json");
assert(base.states.vpn.mode=="primary","priority worker opens primary only after health threshold");
'
