#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export NFT_SECTION_TEST="$WORK_DIR"
mkdir "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
case "$*" in
  'list table inet Fixture') test ! -e "$NFT_SECTION_TEST/absent"; exit $?;;
  '-f -') cat >"$NFT_SECTION_TEST/applied"; test ! -e "$NFT_SECTION_TEST/reject"; exit $?;;
esac
exit 1
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
python3 - "$WORK_DIR" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
section={'.name':'vpn','.type':'section','enabled':'1','action':'proxy',
         'ip_cidr':['203.0.113.5','2001:db8::5'],'ports':['80','443'],
         'source_ip_cidr':['192.168.1.5'],'fully_routed_ips':['192.168.1.6']}
(p/'fixture.json').write_text(json.dumps({'section':[section]}))
(p/'domain.txt').write_text('198.51.100.10\n2001:db8::10\n')
(p/'community.txt').write_text('198.51.100.20\n2001:db8::20\n')
(p/'custom.json').write_text(json.dumps({'version':3,'rules':[{'ip_cidr':['198.51.100.30','2001:db8::30'],'port':[443]}]}))
(p/'manifest.json').write_text(json.dumps([{'kind':'plain','path':str(p/'domain.txt')},
 {'kind':'plain','path':str(p/'community.txt')},{'kind':'source','path':str(p/'custom.json')}]))
PY
apply() {
  ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/trafira/files/usr/lib/nft/apply.uc" \
    nft-replace-section-subnets-fixture "$WORK_DIR/fixture.json" vpn "$WORK_DIR/manifest.json" Fixture
}
apply
python3 - "$WORK_DIR/applied" <<'PY'
import sys
text=open(sys.argv[1]).read(); lines=text.splitlines()
expected=['subnets','subnets6','ip_ports','ip6_ports']
assert lines[:4]==['flush set inet Fixture trafira_rule_vpn_'+s for s in expected],text
for value in ['203.0.113.5 . 80','2001:db8::5 . 443','198.51.100.10 . 80',
              '2001:db8::20 . 443','198.51.100.30 . 443','2001:db8::30 . 443']:
    assert value in text,(value,text)
assert '198.51.100.30 . 80' not in text,'custom port scope was widened'
assert not any(word in text for word in ['_sources','_fully_sources','_ports {','add rule','delete table']),text
PY
cp "$WORK_DIR/applied" "$WORK_DIR/previous"
touch "$WORK_DIR/reject"
if apply; then echo 'FAIL: rejected atomic replacement reported success' >&2; exit 1; fi
rm "$WORK_DIR/reject"
rm "$WORK_DIR/domain.txt"
rm "$WORK_DIR/applied"
if apply; then echo 'FAIL: missing aggregate input reported success' >&2; exit 1; fi
test ! -e "$WORK_DIR/applied" # even the flush must remain uncommitted
touch "$WORK_DIR/absent"
set +e
apply
status=$?
set -e
test "$status" -eq 2
test ! -e "$WORK_DIR/applied"
printf 'Section nft replacement: complete union, port scope, atomic errors and absent table passed\n'
