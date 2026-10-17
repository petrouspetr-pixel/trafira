#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Real nft transaction checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
namespace="trafira-nft-$$"
cleanup() { ip netns del "$namespace" 2>/dev/null || true; rm -rf "$WORK_DIR"; }
trap cleanup EXIT
ip netns add "$namespace"
ip -n "$namespace" link set lo up
cat >"$WORK_DIR/apply.uc" <<'UC'
let t=require("nft.transaction").create();
if(ARGV[0]=="replace")t.command(["delete","table","inet","Fixture"]);
t.append("add table inet Fixture\nadd chain inet Fixture select\nadd chain inet Fixture output { type route hook output priority -150; policy accept; }\n");
t.append("add set inet Fixture v4 { type ipv4_addr; flags interval; auto-merge; }\nadd element inet Fixture v4 { 192.0.2.0/24, 198.51.100.0/24 }\n");
t.append("add set inet Fixture v6 { type ipv6_addr; flags interval; auto-merge; }\nadd element inet Fixture v6 { 2001:db8::/32 }\n");
t.append("add rule inet Fixture output udp dport 10001-10004 jump select\n");
t.append("add rule inet Fixture select udp dport 10001 counter return comment \"bypass\"\n");
t.append("add rule inet Fixture select udp dport 10002 counter drop comment \"adblock\"\n");
t.append("add rule inet Fixture select udp dport { 10001, 10003 } meta mark set 0x4000000 counter return comment \"awg\"\n");
t.append("add rule inet Fixture select udp dport 10004 meta mark set 0x2000001 counter return comment \"zapret2\"\n");
if(ARGV[1]=="fail")t.append("add rule inet Fixture nonexistent counter drop\n");
exit(t.commit()?0:1);
UC
apply() { ip netns exec "$namespace" ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/apply.uc" "$@"; }
apply new
ip netns exec "$namespace" nft -j list table inet Fixture >"$WORK_DIR/before"
if apply replace fail 2>"$WORK_DIR/failure"; then echo 'invalid transaction succeeded' >&2; exit 1; fi
ip netns exec "$namespace" nft -j list table inet Fixture >"$WORK_DIR/after"
cmp "$WORK_DIR/before" "$WORK_DIR/after" # old table, handles, rules and elements survive
apply replace
ip netns exec "$namespace" python3 - <<'PY'
import socket
for family,host in [(socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')]:
    for port in range(10001,10005):
        with socket.socket(family,socket.SOCK_DGRAM) as s:
            try: s.sendto(b'check',(host,port))
            except PermissionError:
                if port!=10002: raise # intentional local drop returns EPERM
PY
ip netns exec "$namespace" nft -j list table inet Fixture >"$WORK_DIR/counters"
python3 - "$WORK_DIR/counters" <<'PY'
import json,sys
rules=[x['rule'] for x in json.load(open(sys.argv[1]))['nftables'] if 'rule' in x and x['rule'].get('comment')]
assert [r['comment'] for r in rules]==['bypass','adblock','awg','zapret2']
for rule in rules:
    packets=sum(e['counter']['packets'] for e in rule['expr'] if 'counter' in e)
    assert packets==2,(rule['comment'],packets) # IPv4 + IPv6; bypass wins over overlapping AWG
print('Real nft: atomic rollback, IPv4/IPv6 elements, bypass/block/AWG/zapret2 packet priority passed')
PY
