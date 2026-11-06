#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Direct bootstrap DNS checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
namespace="trafira-direct-dns-$$"
cleanup() {
  ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$namespace" 2>/dev/null || true
  rm -rf "/etc/netns/$namespace" "$WORK_DIR"
}
trap cleanup EXIT
ip netns add "$namespace"
ip -n "$namespace" link set lo up
mkdir -p "/etc/netns/$namespace" "$WORK_DIR/cache"
printf 'nameserver 127.0.0.42\noptions timeout:1 attempts:1\n' >"/etc/netns/$namespace/resolv.conf"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=cold-list.invalid' \
  -addext 'subjectAltName=DNS:cold-list.invalid' -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" >/dev/null 2>&1
ip netns exec "$namespace" python3 "$ROOT_DIR/tests/helpers/ruleset_direct_dns_server.py" "$WORK_DIR" >"$WORK_DIR/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  [ ! -e "$WORK_DIR/ready" ] || break
  sleep 0.1
done
test -e "$WORK_DIR/ready"
export CURL_CA_BUNDLE="$WORK_DIR/cert.pem"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib" TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export DIRECT_BOOTSTRAP_TEST="$WORK_DIR"
ip netns exec "$namespace" curl --noproxy '*' --resolve cold-list.invalid:18443:127.0.0.2 \
  --fail --silent --max-time 2 https://cold-list.invalid:18443/rules.json >/dev/null
if ip netns exec "$namespace" curl --noproxy '*' --fail --silent --max-time 2 https://cold-list.invalid:18443/rules.json >/dev/null; then
  echo 'FAIL: system DNS unexpectedly works; cold-start fixture is invalid' >&2
  exit 1
fi
cat >"$WORK_DIR/driver.uc" <<'UC'
let fs=require("fs"),b=require("singbox.ruleset_bootstrap"),cache=require("singbox.ruleset_cache");
let root=getenv("DIRECT_BOOTSTRAP_TEST"),path=root+"/config.json";
if(ARGV[0]=="cold"){
 let c={outbounds:[{type:"socks",tag:"production",server:"127.0.0.3",server_port:1080}],
  dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"127.0.0.2",server_port:15353}]},
  route:{final:"production",rule_set:[{type:"remote",tag:"direct",url:"https://cold-list.invalid:18443/rules.json",format:"source",http_client:{}}]}};
 fs.writefile(path,sprintf("%J",c));
}
let before=fs.readfile(path),ok=b.prepare_file(path,"1.14.1");
if(ARGV[0]=="missing-offline"){
 assert(!ok,"missing list and unavailable bootstrap DNS must fail closed");
 assert(fs.readfile(path)==before,"failed cold preparation must preserve config bytes");
}else{
 assert(ok,"direct list hostname must resolve independently of the stopped main core");
 let c=json(fs.readfile(path)),r=c.route.rule_set[0];
 assert(cache.validate(r,r.initial_path),"only a complete validated snapshot enables startup");
 assert(c.route.final=="production" && length(c.outbounds)==1,"main traffic routing must not change");
 if(ARGV[0]=="cached")assert(fs.readfile(path)==before,"offline cached startup must not rewrite the config");
}
UC
ip netns exec "$namespace" ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" cold
grep -qx cold-list.invalid "$WORK_DIR/dns.log"
queries="$(wc -l <"$WORK_DIR/dns.log")"
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
ip netns exec "$namespace" ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" cached
test "$(wc -l <"$WORK_DIR/dns.log")" -eq "$queries"
rm "$TRAFIRA_RULESET_CACHE_DIR/"*.snapshot
ip netns exec "$namespace" env TRAFIRA_BOOTSTRAP_TEST_BUDGET=2 ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" missing-offline
test -z "$(ip netns pids "$namespace")"
printf 'Real direct TLS bootstrap: independent DNS, offline cache, failure preservation and cleanup passed\n'
