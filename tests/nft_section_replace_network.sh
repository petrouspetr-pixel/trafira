#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Section nft replacement kernel checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
namespace="trafira-section-$$"
cleanup() { ip netns del "$namespace" 2>/dev/null || true; rm -rf "$WORK_DIR"; }
trap cleanup EXIT
ip netns add "$namespace"
ip -n "$namespace" link set lo up
python3 - "$WORK_DIR" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); section={'.name':'vpn','.type':'section','enabled':'1','action':'proxy',
 'ip_cidr':['203.0.113.5','2001:db8::5'],'ports':['80','443'],
 'source_ip_cidr':['192.168.1.5'],'fully_routed_ips':['192.168.1.6']}
(p/'fixture.json').write_text(json.dumps({'section':[section]}))
(p/'domain.txt').write_text('198.51.100.10\n203.0.113.5\n2001:db8::10\n')
(p/'community.txt').write_text('198.51.100.20\n2001:db8::20\n')
(p/'custom.json').write_text(json.dumps({'version':3,'rules':[{'ip_cidr':['198.51.100.30','2001:db8::30'],'port':[443]}]}))
(p/'manifest.json').write_text(json.dumps([{'kind':'plain','path':str(p/'domain.txt')},
 {'kind':'plain','path':str(p/'community.txt')},{'kind':'source','path':str(p/'custom.json')}]))
PY
ip netns exec "$namespace" nft -f - <<'NFT'
add table inet Fixture
add set inet Fixture trafira_rule_vpn_subnets { type ipv4_addr; flags interval; auto-merge; }
add set inet Fixture trafira_rule_vpn_subnets6 { type ipv6_addr; flags interval; auto-merge; }
add set inet Fixture trafira_rule_vpn_ip_ports { type ipv4_addr . inet_service; flags interval; auto-merge; }
add set inet Fixture trafira_rule_vpn_ip6_ports { type ipv6_addr . inet_service; flags interval; auto-merge; }
add set inet Fixture trafira_rule_vpn_sources { type ipv4_addr; elements = { 192.168.1.5 }; }
add set inet Fixture trafira_rule_vpn_fully_sources { type ipv4_addr; elements = { 192.168.1.6 }; }
add set inet Fixture trafira_rule_other_subnets { type ipv4_addr; elements = { 198.51.100.99 }; }
add chain inet Fixture route_select { type filter hook output priority 0; policy accept; }
add rule inet Fixture route_select ip daddr . udp dport @trafira_rule_vpn_ip_ports counter accept comment "vpn"
add rule inet Fixture route_select ip6 daddr . udp dport @trafira_rule_vpn_ip6_ports counter accept comment "vpn6"
add rule inet Fixture route_select ip daddr @trafira_rule_other_subnets counter accept comment "other"
NFT
apply() {
  ip netns exec "$namespace" ucode -L "$ROOT_DIR/trafira/files/usr/lib" \
    "$ROOT_DIR/trafira/files/usr/lib/nft/apply.uc" nft-replace-section-subnets-fixture \
    "$WORK_DIR/fixture.json" vpn "$WORK_DIR/manifest.json" Fixture
}
model() { ip netns exec "$namespace" nft -j list table inet Fixture >"$1"; }
apply
printf '198.51.100.11\n2001:db8::11\n' >"$WORK_DIR/domain.txt"
apply
model "$WORK_DIR/replaced.json"
python3 - "$WORK_DIR/replaced.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); text=json.dumps(d)
assert '198.51.100.10' not in text and '2001:db8::10' not in text,'removed source IP survived'
for ip in ['198.51.100.11','2001:db8::11','203.0.113.5','2001:db8::5',
           '198.51.100.20','2001:db8::20','198.51.100.30','2001:db8::30',
           '192.168.1.5','192.168.1.6','198.51.100.99']:
    assert ip in text,(ip,text)
rules=[x['rule'] for x in d['nftables'] if 'rule' in x]
assert [x['comment'] for x in rules]==['vpn','vpn6','other'],'priority/order changed'
sets={x['set']['name']:x['set'] for x in d['nftables'] if 'set' in x}
for family in ['ip_ports','ip6_ports']:
    values=json.dumps(sets['trafira_rule_vpn_'+family]['elem'])
    own='198.51.100.30' if family=='ip_ports' else '2001:db8::30'
    tuples=[e['concat'] for e in sets['trafira_rule_vpn_'+family]['elem'] if isinstance(e,dict) and 'concat' in e]
    assert [e[1] for e in tuples if e[0]==own]==[443],values
PY
# A kernel error after the flush commands must preserve the exact old model.
mkdir "$WORK_DIR/bin"
real_nft="$(command -v nft)"
cat >"$WORK_DIR/bin/nft" <<SH
#!/bin/sh
if [ "\$*" = '-f -' ]; then
  { cat; printf '\nadd element inet Fixture nonexistent { 1 }\n'; } | "$real_nft" -f -
else
  exec "$real_nft" "\$@"
fi
SH
chmod +x "$WORK_DIR/bin/nft"
if PATH="$WORK_DIR/bin:$PATH" apply; then echo 'FAIL: rejected nft replacement succeeded' >&2; exit 1; fi
model "$WORK_DIR/failed.json"
cmp "$WORK_DIR/replaced.json" "$WORK_DIR/failed.json"
rm "$WORK_DIR/domain.txt"
if apply; then echo 'FAIL: missing source replaced a complete aggregate' >&2; exit 1; fi
model "$WORK_DIR/missing.json"
cmp "$WORK_DIR/replaced.json" "$WORK_DIR/missing.json"
ip netns exec "$namespace" nft delete table inet Fixture
set +e
apply
status=$?
set -e
test "$status" -eq 2
printf 'Actual nft section union replaces removed IPs, preserves scope/priority and rolls back kernel errors\n'
