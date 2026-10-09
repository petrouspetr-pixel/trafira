#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Router-origin network checks run in the dedicated privileged CI job'
  exit 0
fi
[ "$(id -u)" = 0 ] || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
router="trafira-ro-r-$$"; server="trafira-ro-s-$$"; client="trafira-ro-c-$$"
cleanup() {
 for ns in "$router" "$server" "$client"; do
  ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$ns" 2>/dev/null || true
 done
 rm -rf "$WORK_DIR"
}
trap cleanup EXIT
for ns in "$router" "$server" "$client"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
ip link add ro-wan type veth peer name ro-server
ip link set ro-wan netns "$router"; ip link set ro-server netns "$server"
ip link add ro-lan type veth peer name ro-client
ip link set ro-lan netns "$router"; ip link set ro-client netns "$client"
ip -n "$router" addr add 198.51.100.1/24 dev ro-wan
ip -n "$server" addr add 198.51.100.2/24 dev ro-server
ip -n "$router" -6 addr add 2001:db8:1::1/64 dev ro-wan nodad
ip -n "$server" -6 addr add 2001:db8:1::2/64 dev ro-server nodad
ip -n "$router" addr add 192.0.2.1/24 dev ro-lan
ip -n "$client" addr add 192.0.2.2/24 dev ro-client
ip -n "$router" link set ro-wan up; ip -n "$router" link set ro-lan up
ip -n "$server" link set ro-server up; ip -n "$client" link set ro-client up
ip -n "$client" route add default via 192.0.2.1
ip -n "$server" route add 192.0.2.0/24 via 198.51.100.1
ip netns exec "$router" sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.ro-wan.rp_filter=0 net.ipv4.conf.lo.rp_filter=0 net.ipv4.conf.all.route_localnet=1
for family in -4 -6; do
 ip -n "$router" "$family" rule add pref 105 fwmark 0x04000000/0x04000000 table 200
 ip -n "$router" "$family" route add local default dev lo table 200
done
ip netns exec "$server" python3 "$ROOT_DIR/tests/helpers/failure_policy_servers.py" http >"$WORK_DIR/http.log" 2>&1 &
ip netns exec "$router" python3 -m http.server 18080 --bind 192.0.2.1 --directory "$WORK_DIR" >"$WORK_DIR/management.log" 2>&1 &
cat >"$WORK_DIR/server.json" <<'JSON'
{"log":{"level":"error"},"inbounds":[{"type":"socks","tag":"proxy","listen":"0.0.0.0","listen_port":1080}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
ip netns exec "$server" sing-box run -c "$WORK_DIR/server.json" >"$WORK_DIR/server.log" 2>&1 &
server_pid=$!
cat >"$WORK_DIR/udp.py" <<'PY'
import socket,threading,struct

def serve(family,address):
 s=socket.socket(family,socket.SOCK_DGRAM)
 if family==socket.AF_INET6:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
 s.bind((address,18081))
 while True:
  data,peer=s.recvfrom(2048);s.sendto(data,peer)
def dns():
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('0.0.0.0',53))
 while True:
  data,peer=s.recvfrom(2048)
  if len(data)<17:continue
  end=12
  while end<len(data) and data[end]:end+=data[end]+1
  if end+5>len(data):continue
  question=data[12:end+5];qtype=struct.unpack('!H',data[end+1:end+3])[0]
  address=socket.inet_pton(socket.AF_INET,'198.51.100.2') if qtype==1 else socket.inet_pton(socket.AF_INET6,'2001:db8:1::2')
  answer=b'\xc0\x0c'+struct.pack('!HHIH',qtype,1,0,len(address))+address
  s.sendto(data[:2]+b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00'+question+answer,peer)
threading.Thread(target=dns,daemon=True).start()
threading.Thread(target=serve,args=(socket.AF_INET,'0.0.0.0'),daemon=True).start()
serve(socket.AF_INET6,'::')
PY
ip netns exec "$server" python3 "$WORK_DIR/udp.py" >"$WORK_DIR/udp.log" 2>&1 &
ucode -L "$LIB" -e '
let r=require("config.router_origin"),fs=require("fs");
let c={log:{level:"error"},inbounds:[],outbounds:[{type:"socks",tag:"vpn-out",server:"proxy.fixture.test",server_port:1080,version:"5",domain_resolver:"dns-server"}],route:{rules:[{action:"sniff",inbound:["unused"]},{action:"hijack-dns",protocol:"dns"}],default_mark:0x08000000,final:"vpn-out"},dns:{servers:[{type:"udp",tag:"dns-server",server:"198.51.100.2"}],rules:[]}};
r.attach(c,{router_origin_enabled:"1",router_origin_section:"vpn"},[{".name":"vpn",action:"connection"}]);
require("core.common").strip_internal_fields(c);
fs.writefile(ARGV[0],sprintf("%J",c));
fs.writefile(ARGV[1],r.nft("RouterTest","localv4","localv6","0x04000000",{dns:["198.51.100.2"],ntp:[],vpn:[],vpn_ports:[]}));
' "$WORK_DIR/router.json" "$WORK_DIR/router.nft"
ip netns exec "$router" sing-box check -c "$WORK_DIR/router.json"
ip netns exec "$router" sing-box run -c "$WORK_DIR/router.json" >"$WORK_DIR/router.log" 2>&1 &
base_rules() {
 ip netns exec "$router" nft -f - <<'NFT'
add table inet RouterTest
flush table inet RouterTest
add set inet RouterTest localv4 { type ipv4_addr; flags interval; elements = { 127.0.0.0/8, 192.0.2.0/24 }; }
add set inet RouterTest localv6 { type ipv6_addr; flags interval; elements = { ::1/128, fe80::/10 }; }
add chain inet RouterTest mangle_output { type route hook output priority -150; policy accept; }
add chain inet RouterTest proxy { type filter hook prerouting priority -100; policy accept; }
NFT
}
base_rules
# OUTPUT still exposes the old oif before route-hook rerouting completes.
# POSTROUTING counts only packets actually leaving through WAN.
ip netns exec "$router" nft -f - <<'NFT'
table inet Audit {
 counter direct4 {}
 counter direct6 {}
 chain egress {
 type filter hook postrouting priority 0; policy accept;
 oifname "ro-wan" ip daddr 198.51.100.2 meta l4proto { tcp, udp } th dport { 18080,18081 } counter name direct4
 oifname "ro-wan" ip6 daddr 2001:db8:1::2 meta l4proto { tcp, udp } th dport { 18080,18081 } counter name direct6
 }
}
NFT
sleep 0.6
request() { ip netns exec "$router" curl --noproxy '*' --max-time 3 -fsS "http://$1:18080/" >/dev/null; }
working() { request 198.51.100.2; request '[2001:db8:1::2]'; }
# Disabled preserves direct behavior, enabled changes only router output.
working
sleep 1
ip netns exec "$router" nft reset counters table inet Audit >/dev/null
ip netns exec "$router" nft -f "$WORK_DIR/router.nft"
working
ip netns exec "$router" python3 - <<'PY'
import socket
for family,host in [(socket.AF_INET,'198.51.100.2'),(socket.AF_INET6,'2001:db8:1::2')]:
 s=socket.socket(family,socket.SOCK_DGRAM);s.settimeout(3)
 s.sendto(b'router-origin', (host,18081));assert s.recv(64)==b'router-origin';s.close()
PY
ip netns exec "$router" nft -j list counters table inet Audit | python3 -c 'import json,sys; cs=[x["counter"] for x in json.load(sys.stdin)["nftables"] if "counter" in x]; assert len(cs)==2 and all(c["packets"]==0 for c in cs),cs'
ip netns exec "$client" curl --noproxy '*' --max-time 3 -fsS http://198.51.100.2:18080/ >/dev/null
ip netns exec "$client" curl --noproxy '*' --max-time 3 -fsS http://192.0.2.1:18080/ >/dev/null
# A lost selected proxy never turns router traffic into an implicit direct path.
kill "$server_pid"
sleep 0.2
for address in 198.51.100.2 '[2001:db8:1::2]'; do
 if request "$address" 2>/dev/null; then echo 'Router traffic escaped failed proxy' >&2; exit 1; fi
done
ip netns exec "$server" sing-box run -c "$WORK_DIR/server.json" >"$WORK_DIR/server-restarted.log" 2>&1 &
sleep 0.4
# Rebuilding after a network event reinstalls exclusions and routing together.
base_rules
ip netns exec "$router" nft -f "$WORK_DIR/router.nft"
working
base_rules
working
printf 'Router-origin TCP/UDP IPv4/IPv6, LAN, management, rebuild and disable passed\n'
