#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_CONFIG_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" DNS_EXIT=0
export REAL_UCODE="$(command -v ucode)"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in *service/state.uc*sing-box-service-running*) exit 0;; esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit "$DNS_EXIT"\n' >"$WORK_DIR/bin/dig"
printf '#!/bin/sh\necho unexpected-network >&2\nexit 91\n' >"$WORK_DIR/bin/curl"
chmod +x "$WORK_DIR/bin/"*
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
before=$(sha256sum "$TRAFIRA_UCI_STATE_FILE")
for mode in sync background; do
 for scenario in exact suffix list earlier-ip compound-ip earlier-allow missing-list dns-only router; do
  node - "$WORK_DIR" "$scenario" <<'JS'
const fs=require('fs'),root=process.argv[2],scenario=process.argv[3];
let rules=[{domain:'static.popmechanic.ru',action:'reject'}],sets=[];
if(scenario==='suffix')rules=[{domain_suffix:'popmechanic.ru',action:'reject'}];
if(scenario==='list'){sets=[{type:'inline',tag:'ads',rules:[{domain_suffix:'popmechanic.ru'}]}];rules=[{rule_set:'ads',action:'reject'}];}
if(scenario==='earlier-ip')rules.unshift({ip_cidr:'203.0.113.0/24',action:'route',outbound:'vpn-out'});
if(scenario==='compound-ip')rules=[{type:'logical',mode:'and',rules:[{domain:'static.popmechanic.ru'},{ip_cidr:'203.0.113.0/24'}],action:'reject'}];
if(scenario==='earlier-allow')rules.unshift({domain:'static.popmechanic.ru',action:'route',outbound:'direct-out'});
if(scenario==='missing-list')rules.unshift({rule_set:'missing',action:'route',outbound:'vpn-out'});
if(scenario==='dns-only')rules=[];
fs.writeFileSync(root+'/config.json',JSON.stringify({inbounds:[{tag:'dns-health-active-main-in',listen:'127.0.0.42',listen_port:12053}],route:{rules,rule_set:sets,final:'direct-out'},dns:{rules:[{domain:'static.popmechanic.ru',action:'predefined',rcode:'NXDOMAIN'}],final:'dns-server',strategy:'ipv4_only'},outbounds:[]}));
JS
  ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config"),u=require("core.uci");assert(a.save(a.capture(u.get_all("trafira","settings"),[])));'
  for DNS_EXIT in 0 9; do
   export DNS_EXIT
   ucode -L "$TRAFIRA_LIB" - "$mode" "$scenario" "$WORK_DIR" <<'UC'
let mode=ARGV[0],scenario=ARGV[1],root=ARGV[2];
let request={domain:"static.popmechanic.ru",source:scenario=="router"?{kind:"router"}:{kind:"device",ip:"192.0.2.5"},port:443,network:"tcp",protocol:"tls"};
let r=require("diagnostics.route_analysis").explain(sprintf("%J",request),{background:mode=="background",workspace:root});
assert(r.success,sprintf("%J",r));
assert(r.dns_query.performed && !length(r.dns_query.addresses),"fixture must have no destination IP");
assert(r.dns_query.status==(getenv("DNS_EXIT")=="0"?"no_address":"timeout"),"DNS outcome must remain visible");
if(index(["exact","suffix","list"],scenario)>=0) {
 assert(r.decision.status=="blocked",mode+" "+scenario+": a confirmed domain block must not become indeterminate after DNS failure");
 assert(r.decision.rule_index==0 && !length(r.decision.missing),"preserve the matched block rule");
 assert(r.decision.trace[0].action=="reject" && r.decision.trace[0].match=="yes","preserve the explanation trace");
 assert(!r.connection && !r.selector && !length(r.destinations),"do not invent an address or selected proxy");
} else {
 assert(r.decision.status=="indeterminate",scenario+": unknown earlier conditions or missing capture state must not be skipped");
 if(index(["earlier-ip","compound-ip"],scenario)>=0)assert(r.decision.rule_index==0,"preserve earlier IP-dependent rule order");
 if(scenario=="missing-list")assert(index(r.decision.missing,"rule_set:missing")>=0,"missing earlier list must remain unknown");
}
UC
  done
 done
done
test "$(sha256sum "$TRAFIRA_UCI_STATE_FILE")" = "$before"
echo 'blocked routes without destination IP checks passed'
