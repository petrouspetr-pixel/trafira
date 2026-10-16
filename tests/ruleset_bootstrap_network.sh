#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Rule-set bootstrap transport checks run in the isolated network CI job'
  exit 0
fi
[ "$(id -u)" = 0 ] || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
router="trafira-rs-r-$$"
server="trafira-rs-s-$$"
cleanup() {
  for namespace in "$router" "$server"; do
    ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$namespace" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
ip netns add "$router"
ip netns add "$server"
ip link add veth-r type veth peer name veth-s
ip link set veth-r netns "$router"
ip link set veth-s netns "$server"
for namespace in "$router" "$server"; do ip -n "$namespace" link set lo up; done
ip -n "$router" addr add 198.51.100.1/24 dev veth-r
ip -n "$server" addr add 198.51.100.2/24 dev veth-s
ip -n "$router" link set veth-r up
ip -n "$server" link set veth-s up
mkdir -p "$WORK_DIR/http"
printf '%s' '{"version":3,"rules":[{"domain_suffix":["bootstrap-test.example"]}]}' >"$WORK_DIR/http/rules.json"
ip netns exec "$server" python3 -m http.server 18080 --bind 198.51.100.2 --directory "$WORK_DIR/http" >"$WORK_DIR/http.log" 2>&1 &
ip netns exec "$server" python3 "$ROOT_DIR/tests/helpers/failure_policy_servers.py" 1080 >"$WORK_DIR/proxy.log" 2>&1 &
proxy_pid=$!
for _ in $(seq 1 50); do
  if ip netns exec "$server" curl --noproxy '*' --fail --silent --max-time 1 http://198.51.100.2:18080/rules.json >/dev/null; then break; fi
  sleep 0.1
done
ip netns exec "$router" nft -f - <<'NFT'
table inet bootstrap_test {
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr 198.51.100.2 tcp dport 18080 counter reject
  }
}
NFT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_BOOTSTRAP_TEST_DIR="$WORK_DIR"
cat >"$WORK_DIR/driver.uc" <<'UC'
let fs = require("fs"), b = require("singbox.ruleset_bootstrap"), cache = require("singbox.ruleset_cache");
let provenance = require("singbox.provenance"), store = require("singbox.failure_store");
let path = getenv("TRAFIRA_BOOTSTRAP_TEST_DIR") + "/candidate.json";
if (ARGV[0] == "init") {
  let c = {outbounds:[{type:"selector",tag:"download",default:"dead",outbounds:["dead","good"]},
    {type:"socks",tag:"dead",server:"198.51.100.2",server_port:1081,version:"5"},
    {type:"socks",tag:"good",server:"198.51.100.2",server_port:1080,version:"5"}],
    dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"192.0.2.53",server_port:53}]},
    route:{rule_set:[{type:"remote",tag:"test",format:"source",url:"http://198.51.100.2:18080/rules.json",http_client:{detour:"download"}}]}};
  fs.writefile(path,sprintf("%J",c));
  assert(provenance.save(path,{schema:1,route:[],dns:[]}),"save real-transport provenance fixture");
  assert(store.save_base(path,c,[{".name":"protected",action:"connection",failure_policy:"block"}]),"save real-transport failure baseline");
}
let before = fs.readfile(path);
// The pinned 1.12 binary exercises real bootstrap transport and validation.
// The version argument enables snapshot preparation; the main configuration
// with initial_path is not started by this transport test.
let ok = b.prepare_file(path,"1.14.1");
if (ARGV[0] == "missing-offline") {
  assert(!ok,"offline first boot must fail closed");
  assert(fs.readfile(path)==before,"failed preparation preserves prior bytes");
} else {
  assert(ok,"working alternate downloads through the selected proxy");
  let c = json(fs.readfile(path)), rule = c.route.rule_set[0];
  assert(rule.initial_path==cache.path(rule) && cache.validate(rule,rule.initial_path),"real core validated a nonempty snapshot");
  assert(provenance.load(path) != null,"real preparation preserves provenance digest");
  let base = store.load(path);
  assert(base != null && base.config.route.rule_set[0].initial_path == rule.initial_path,"real preparation preserves failure baseline digest and snapshot");
}
UC
ip netns exec "$router" ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" init
ip netns exec "$router" nft list chain inet bootstrap_test output | grep -q 'counter packets 0 bytes 0 reject'
kill "$proxy_pid"
wait "$proxy_pid" 2>/dev/null || true
ip netns exec "$router" ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" cached-offline
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
ip netns exec "$router" ucode -L "$TRAFIRA_LIB" "$WORK_DIR/driver.uc" missing-offline
ip netns exec "$router" nft list chain inet bootstrap_test output | grep -q 'counter packets 0 bytes 0 reject'
printf 'Rule-set bootstrap real transport checks passed (main initial_path startup requires >=1.14)\n'
