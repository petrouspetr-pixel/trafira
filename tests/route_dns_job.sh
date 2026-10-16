#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_CONFIG_FILE="$WORK_DIR/uci"
export REAL_UCODE="$(command -v ucode)"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in *service/state.uc*sing-box-service-running*) exit 0;; esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = rule-set ] && [ "$4" = -o ] || exit 1
printf 'codec\n' >>"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls"
sleep 0.15
cp "$3" "$5"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf network >"$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
exit 91
SH
chmod +x "$WORK_DIR/bin/"*

cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '203.0.113.1\n203.0.113.2\n203.0.113.3\n203.0.113.4\n'
SH
chmod +x "$WORK_DIR/bin/dig"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],sets=[];
for(let i=0;i<5;i++){const path=dir+'/list-'+i+'.json';fs.writeFileSync(path,JSON.stringify({version:3,rules:[{domain:i===4?'target.example':'other-'+i+'.example'}]}));sets.push({tag:'set-'+i,type:'local',format:'source',path});}
fs.writeFileSync(dir+'/config.json',JSON.stringify({inbounds:[{tag:'dns-health-active-main-in',listen:'127.0.0.42',listen_port:12053}],route:{rule_set:sets,rules:[{rule_set:sets.map(s=>s.tag),outbound:'vpn-out'}],final:'direct-out'},dns:{strategy:'ipv4_only',rules:[],final:'dns-server'},outbounds:[]}));
JS
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$WORK_DIR/uci"
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config"),u=require("core.uci");assert(a.save(a.capture(u.get_all("trafira","settings"),[])));'
for pass in cold warm; do
 ucode -L "$TRAFIRA_LIB" -e 'let r=require("diagnostics.route_analysis").explain(ARGV[0],{background:true,workspace:ARGV[1]});assert(r.success && r.decision.outbound=="vpn-out",sprintf("%J",r));assert(length(r.destinations)==4,"all DNS addresses checked");' '{"domain":"target.example","source":{"kind":"device","ip":"192.0.2.5"},"port":443,"network":"tcp"}' "$WORK_DIR"
 test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 5
done
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
printf 'four DNS addresses share each decoded list once, warm result cache reused\n'
