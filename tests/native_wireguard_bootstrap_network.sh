#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Native WireGuard bootstrap checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
router="trafira-wg-r-$$"
server="trafira-wg-s-$$"
cleanup() {
  for namespace in "$router" "$server"; do
    ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$namespace" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
umask 077
wg genkey >"$WORK_DIR/client.key"
wg genkey >"$WORK_DIR/server.key"
wg pubkey <"$WORK_DIR/client.key" >"$WORK_DIR/client.pub"
wg pubkey <"$WORK_DIR/server.key" >"$WORK_DIR/server.pub"
ip netns add "$router"
ip netns add "$server"
ip link add veth-wr type veth peer name veth-ws
ip link set veth-wr netns "$router"
ip link set veth-ws netns "$server"
for namespace in "$router" "$server"; do ip -n "$namespace" link set lo up; done
ip -n "$router" addr add 198.51.100.1/24 dev veth-wr
ip -n "$server" addr add 198.51.100.2/24 dev veth-ws
ip -n "$router" link set veth-wr up
ip -n "$server" link set veth-ws up
ip -n "$router" route add default via 198.51.100.2
ip -n "$server" link add wg-server type wireguard
ip netns exec "$server" wg set wg-server private-key "$WORK_DIR/server.key" listen-port 51820 peer "$(cat "$WORK_DIR/client.pub")" allowed-ips 10.200.0.2/32
ip -n "$server" addr add 10.200.0.1/24 dev wg-server
ip -n "$server" link set wg-server up
mkdir -p "$WORK_DIR/http"
printf '%s' '{"version":3,"rules":[{"domain_suffix":["native-wg-test.example"]}]}' >"$WORK_DIR/http/rules.json"
ip netns exec "$server" python3 -m http.server 18080 --bind 10.200.0.1 --directory "$WORK_DIR/http" >"$WORK_DIR/http.log" 2>&1 &
for _ in $(seq 1 50); do
  if ip netns exec "$server" curl --noproxy '*' -fsS --max-time 1 http://10.200.0.1:18080/rules.json >/dev/null 2>&1; then break; fi
  sleep 0.1
done
ip netns exec "$router" nft -f - <<'NFT'
table inet wg_bootstrap_test {
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr 10.200.0.1 tcp dport 18080 counter reject
  }
}
NFT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_BOOTSTRAP_TEST_BUDGET=6
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],key=n=>fs.readFileSync(`${dir}/${n}`,'utf8').trim();
const c={log:{disabled:true},endpoints:[{type:'wireguard',tag:'wg-native',system:true,name:'boot-wg',listen_port:51821,address:['10.200.0.2/32'],private_key:key('client.key'),peers:[{address:'198.51.100.2',port:51820,public_key:key('server.pub'),allowed_ips:['0.0.0.0/0'],persistent_keepalive_interval:25}]}],outbounds:[{type:'selector',tag:'download',outbounds:['wg-native'],default:'wg-native'}],dns:{servers:[{type:'udp',tag:'bootstrap-dns-server',server:'192.0.2.53'}]},route:{rule_set:[{type:'remote',tag:'test',format:'source',url:'http://10.200.0.1:18080/rules.json',http_client:{detour:'download'}}]}};
fs.writeFileSync(`${dir}/candidate.json`,JSON.stringify(c),{mode:0o600});
JS
run_prepare() {
  ip netns exec "$router" ucode -L "$TRAFIRA_LIB" -e 'exit(require("singbox.ruleset_bootstrap").prepare_file(ARGV[0],"1.14.2")?0:1);' "$WORK_DIR/candidate.json"
}
run_prepare
if ip -n "$router" link show boot-wg >/dev/null 2>&1; then echo 'bootstrap created production interface' >&2; exit 1; fi
ip netns exec "$router" nft list chain inet wg_bootstrap_test output | grep -q 'counter packets 0 bytes 0 reject'
start_main() {
  ip netns exec "$router" sing-box run -c "$WORK_DIR/candidate.json" >"$WORK_DIR/main.log" 2>&1 &
  main_pid=$!
  sleep 1
  if ! kill -0 "$main_pid" 2>/dev/null; then cat "$WORK_DIR/main.log"; exit 1; fi
}
start_main
ip -n "$router" link show boot-wg >/dev/null
run_prepare # Warm preparation must not conflict with the running endpoint.
before=$(ip netns exec "$server" wg show wg-server endpoints)
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
if run_prepare; then echo 'duplicate native peer allowed while main core active' >&2; exit 1; fi
kill -0 "$main_pid"
test "$before" = "$(ip netns exec "$server" wg show wg-server endpoints)"
kill "$main_pid"
wait "$main_pid" 2>/dev/null || true
run_prepare # Refill through WireGuard again after the active peer is stopped.
ip -n "$server" link set wg-server down
run_prepare # Cached preparation and main startup must work offline.
start_main
kill "$main_pid"
wait "$main_pid" 2>/dev/null || true
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
sha256sum "$WORK_DIR/candidate.json" >"$WORK_DIR/before.sha"
if run_prepare; then echo 'offline cold native bootstrap succeeded without lists' >&2; exit 1; fi
sha256sum -c "$WORK_DIR/before.sha"
if ip -n "$router" link show boot-wg >/dev/null 2>&1; then echo 'failed bootstrap left a system interface' >&2; exit 1; fi
ip netns exec "$router" nft list chain inet wg_bootstrap_test output | grep -q 'counter packets 0 bytes 0 reject'
printf 'Native WireGuard cold/warm/offline/active-peer checks passed\n'
