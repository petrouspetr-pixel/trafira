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
if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then
 REAL_SING_BOX=$(command -v sing-box)
 export REAL_SING_BOX
fi
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
if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then exec "$REAL_SING_BOX" "$@"; fi
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
case "$*" in *facebook.com*) printf '203.0.113.1\n203.0.113.2\n';; *) printf '198.51.100.1\n198.51.100.2\n';; esac
SH
chmod +x "$WORK_DIR/bin/dig"
real_sha=$(command -v sha256sum)
cat >"$WORK_DIR/bin/sha256sum" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"\$TRAFIRA_RUNTIME_STATE_DIR/hash-calls"
exec "$real_sha" "\$@"
SH
chmod +x "$WORK_DIR/bin/sha256sum"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],sets=[];
for(const [tag,rules] of [['meta-domains',[{domain_suffix:['instagram.com']}]],['meta-addresses',[{ip_cidr:['203.0.113.0/24']}]],['youtube',[{domain_suffix:['youtube.com','googlevideo.com']}]]]) {const path=dir+'/'+tag+'.json';fs.writeFileSync(path,JSON.stringify({version:3,rules}));if(process.env.TRAFIRA_REAL_CODEC==='1'){const binary=dir+'/'+tag+'.srs';require('child_process').execFileSync(process.env.REAL_SING_BOX,['rule-set','compile',path,'-o',binary]);sets.push({tag,type:'local',format:'binary',path:binary});}else sets.push({tag,type:'local',format:'source',path});}
fs.writeFileSync(dir+'/config.json',JSON.stringify({inbounds:[{tag:'dns-health-active-main-in',listen:'127.0.0.42',listen_port:12053}],route:{rule_set:sets,rules:[{rule_set:['meta-domains','meta-addresses'],action:'route',outbound:'awg-out'},{rule_set:'youtube',action:'route',outbound:'zapret2-out'}],final:'direct-out'},dns:{strategy:'ipv4_only',rules:[{action:"evaluate",server:"dns-server"},{match_response:true,rule_set:"set-4",action:"route",server:"fakeip-server"}],final:'dns-server'},outbounds:[]}));
JS
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$WORK_DIR/uci"
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config"),u=require("core.uci");assert(a.save(a.capture(u.get_all("trafira","settings"),[])));'

# Domain-only Meta, address-based Meta, YouTube, and direct fallback.
for pass in cold warm; do
 for domain in instagram.com facebook.com youtube.com ya.ru; do
  ucode -L "$TRAFIRA_LIB" -e '
   let domain=ARGV[0],r=require("diagnostics.route_analysis").explain(sprintf("%J",{domain,source:{kind:"device",ip:"192.168.10.234"},port:443,network:"tcp",protocol:"tls"}),{background:true,workspace:ARGV[1]});
   let expected=domain=="youtube.com"?"zapret2-out":domain=="ya.ru"?"direct-out":"awg-out";
   assert(r.success && r.decision.outbound==expected,sprintf("%J",r));
   assert(r.dns_query.status=="resolved" && length(r.destinations)==2,"automatic DNS checks both addresses");
   assert(r.dns_policy==null,"do not confuse DNS policy with real lookup");
   for(let d in r.destinations)assert(d.decision.outbound==expected,"same route for both addresses");
  ' "$domain" "$WORK_DIR"
 done
done
# A changed saved list must change the answer, even after warm cache hits.
printf '{"version":3,"rules":[{"domain_suffix":["changed.example"]}]}' >"$WORK_DIR/youtube.json"
if [ "${TRAFIRA_REAL_CODEC:-0}" = 1 ]; then
 "$REAL_SING_BOX" rule-set compile "$WORK_DIR/youtube.json" -o "$WORK_DIR/youtube.srs"
fi
ucode -L "$TRAFIRA_LIB" -e '
 let r=require("diagnostics.route_analysis").explain("{\"domain\":\"youtube.com\",\"source\":{\"kind\":\"device\",\"ip\":\"192.168.10.234\"},\"port\":443,\"network\":\"tcp\"}",{background:true,workspace:ARGV[0]});
 assert(r.decision.outbound=="direct-out","list replacement invalidates cached matching result");
' "$WORK_DIR"
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
printf 'Meta AWG, YouTube Zapret2, direct fallback and list invalidation passed\n'
