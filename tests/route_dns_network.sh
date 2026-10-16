#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Real routing DNS checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
namespace="trafira-route-dns-$$"
cleanup() {
  ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$namespace" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
ip netns add "$namespace"
ip -n "$namespace" link set lo up
cat >"$WORK_DIR/dns.py" <<'PY'
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 15353))
while True:
    data, addr = s.recvfrom(4096)
    end = 12
    while data[end]: end += data[end] + 1
    end += 5
    kind = struct.unpack('!H', data[end-4:end-2])[0]
    answers = [socket.inet_aton('203.0.113.5'), socket.inet_aton('203.0.113.6')] if kind == 1 else []
    response = data[:2] + struct.pack('!HHHHH', 0x8180, 1, len(answers), 0, 0) + data[12:end]
    for answer in answers:
        response += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + answer
    s.sendto(response, addr)
PY
ip netns exec "$namespace" python3 "$WORK_DIR/dns.py" >"$WORK_DIR/dns.log" 2>&1 &
cat >"$WORK_DIR/config.json" <<'JSON'
{"log":{"disabled":true},"inbounds":[{"type":"direct","tag":"dns-health-active-main-in","listen":"127.0.0.42","listen_port":12053}],"dns":{"servers":[{"type":"udp","tag":"dns-server","server":"127.0.0.1","server_port":15353},{"type":"fakeip","tag":"fakeip-server","inet4_range":"198.18.0.0/15","inet6_range":"fc00::/18"}],"rules":[{"inbound":"dns-health-active-main-in","action":"route","server":"dns-server"}],"final":"fakeip-server","strategy":"ipv4_only"},"route":{"rules":[{"inbound":"dns-health-active-main-in","action":"sniff"},{"protocol":"dns","action":"hijack-dns"}]}}
JSON
ip netns exec "$namespace" sing-box run -c "$WORK_DIR/config.json" >"$WORK_DIR/main.log" 2>&1 &
main_pid=$!
for _ in $(seq 1 30); do
  if ip netns exec "$namespace" dig @127.0.0.42 -p 12053 example.org A +short +tcp +timeout=1 +tries=1 2>/dev/null | grep -q '203.0.113.5'; then break; fi
  sleep 0.1
done
if ! kill -0 "$main_pid" 2>/dev/null; then cat "$WORK_DIR/main.log"; exit 1; fi
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
ip netns exec "$namespace" ucode -L "$TRAFIRA_LIB" -e '
let dns=require("diagnostics.route_dns"),fs=require("fs"),c=json(fs.readfile(ARGV[0]));
let report=dns.resolve(c,{domain:"example.org",source:{kind:"device",ip:"192.168.10.234"}},{});
assert(report.status=="resolved" && length(report.addresses)==2,"real main DNS through running sing-box");
assert(report.addresses[0]=="203.0.113.5" && report.addresses[1]=="203.0.113.6","never use fake DNS final for diagnostic addresses");
print("Real sing-box routing DNS and FakeIP isolation passed\n");
' "$WORK_DIR/config.json"
