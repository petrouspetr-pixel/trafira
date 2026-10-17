#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/runtime"
export NFT_COMMANDS="$WORK_DIR/commands" NFT_CALLS="$WORK_DIR/calls" PATH="$WORK_DIR/bin:$PATH"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_RT_TABLES="$WORK_DIR/rt_tables" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
printf '105 trafira\n' >"$TRAFIRA_RT_TABLES"
cat >"$WORK_DIR/bin/nft" <<'PY'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['NFT_CALLS'],'a') as f: f.write(' '.join(args)+'\n')
if args[:2]==['list','table']: sys.exit(int(os.getenv('NFT_MISSING','0')))
text=sys.stdin.read() if args==['-f','-'] else ' '.join(args)+'\n'
with open(os.environ['NFT_COMMANDS'],'a') as f: f.write(text)
sys.exit(int(os.getenv('NFT_FAIL','0')))
PY
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
 'route list table '*) echo 'local default dev lo';;
 '-6 route list table '*) echo 'local default dev lo';;
 '-4 rule list'|'-6 rule list') echo '105: from all fwmark 0x4000000/0x4000000 lookup trafira';;
esac
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*
cat >"$TRAFIRA_UCI_STATE_FILE" <<'UCI'
trafira.settings=settings
trafira.settings.source_network_interfaces=br-lan
trafira.settings.exclude_ntp=1
trafira.settings.exclude_wifi_calling=1
trafira.settings.alice_mode_enabled=1
trafira.settings.alice_list_mode=include
trafira.settings.alice_ips=192.168.1.10
trafira.bypass=section
trafira.bypass.action=bypass
trafira.bypass.ip_cidr=203.0.113.0/24
trafira.adblock=section
trafira.adblock.action=block
trafira.adblock.ip_cidr=198.51.100.0/24
trafira.vpn=section
trafira.vpn.action=proxy
trafira.vpn.ip_cidr=0.0.0.0/0
trafira.vpn.source_ip_cidr=192.168.1.10
trafira.vpn.ports=443
trafira.zapret=section
trafira.zapret.action=zapret
trafira.zapret.ip_cidr=192.0.2.0/24
trafira.zapret2=section
trafira.zapret2.action=zapret2
trafira.zapret2.ip_cidr=192.0.2.0/24
trafira.disabled=section
trafira.disabled.enabled=0
trafira.disabled.action=block
trafira.disabled.ip_cidr=10.0.0.0/8
UCI
args=(trafira TrafiraTable localv4 trafira_subnets trafira_ports trafira_ip_ports trafira_interfaces 0x4000000 0x8000000 198.18.0.0/15 1602 /bin/true 0x01000000 4200 0x40000000 0x20000000 /bin/true 0x02000000 4300 0x40000000 0x20000000 localv6 trafira_subnets6 trafira_ip6_ports fc00::/18 ::1)
runtime="$WORK_DIR/runtime.uc"
# Redirect only the host routing-table registry path; exercise unchanged logic.
python3 - "$ROOT_DIR/trafira/files/usr/lib/nft/apply.uc" "$runtime" "$TRAFIRA_RT_TABLES" <<'PY'
from pathlib import Path
import json,sys
source,target,registry=sys.argv[1:]
Path(target).write_text(Path(source).read_text().replace('"/etc/iproute2/rt_tables"',json.dumps(registry)))
PY
# The old construction path remains available to test command equivalence.
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$runtime" nft-create-full-runtime-from-uci "${args[@]}"
cp "$NFT_COMMANDS" "$WORK_DIR/before"
: >"$NFT_COMMANDS"; : >"$NFT_CALLS"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$runtime" nft-rebuild-runtime-from-uci "${args[@]}"
printf 'delete table inet TrafiraTable\n' >"$WORK_DIR/expected"
cat "$WORK_DIR/before" >>"$WORK_DIR/expected"
diff -u "$WORK_DIR/expected" "$NFT_COMMANDS"
test "$(grep -c '^-f -$' "$NFT_CALLS")" = 1
test "$(wc -l <"$NFT_CALLS")" = 2 # table existence read + one write
if grep -q '^delete table ' "$NFT_CALLS"; then echo 'standalone deletion is forbidden' >&2; exit 1; fi
: >"$NFT_COMMANDS"; : >"$NFT_CALLS"
NFT_MISSING=1 ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$runtime" nft-rebuild-runtime-from-uci "${args[@]}"
diff -u "$WORK_DIR/before" "$NFT_COMMANDS"
: >"$NFT_CALLS"
if NFT_FAIL=1 ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$runtime" nft-rebuild-runtime-from-uci "${args[@]}"; then echo 'nft failure was ignored' >&2; exit 1; fi
test "$(grep -c '^-f -$' "$NFT_CALLS")" = 1
if [ -n "${TRAFIRA_NFT_SCRIPT_OUTPUT:-}" ]; then
  cp "$WORK_DIR/before" "$TRAFIRA_NFT_SCRIPT_OUTPUT/original.nft"
  cp "$WORK_DIR/expected" "$TRAFIRA_NFT_SCRIPT_OUTPUT/replace.nft"
fi

# A large remote list uses bounded batches instead of one process per chunk.
python3 - "$WORK_DIR/large.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(''.join(f'10.{i//256}.{i%256}.1\n' for i in range(16000)))
PY
: >"$NFT_CALLS"; : >"$NFT_COMMANDS"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$runtime" nft-add-file-chunks-to-set "$WORK_DIR/large.txt" TrafiraTable large ips '' 1000
test "$(wc -l <"$NFT_CALLS")" -lt 16
python3 - "$NFT_COMMANDS" <<'PY'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text().splitlines()
elements=[value.strip() for line in lines for value in line.split('{',1)[1].split('}',1)[0].split(',')]
expected=[f'10.{i//256}.{i%256}.1' for i in range(16000)]
assert elements==expected,'all elements and their order must survive batch boundaries'
PY
printf 'nft runtime command equivalence and single-transaction checks passed\n'
