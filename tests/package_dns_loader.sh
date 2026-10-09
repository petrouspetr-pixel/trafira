#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running"
export TRAFIRA_RT_TABLES="$WORK_DIR/rt_tables"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TRAFIRA_INIT="$WORK_DIR/init"
export TRAFIRA_BIN="$WORK_DIR/init"
export TRAFIRA_DNS_APPLY_UC="$WORK_DIR/dns.uc"
export DNS_LOADER_PROBE="$WORK_DIR/loaded"
cat >"$TRAFIRA_UCI_STATE_FILE" <<'EOF'
trafira.settings=settings
trafira.settings.dont_touch_dhcp=0
EOF
cat >"$TRAFIRA_INIT" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TRAFIRA_INIT"
cat >"$TRAFIRA_DNS_APPLY_UC" <<'EOF'
let uci = require("core.uci");
let fs = require("fs");
if (ARGV[0] != "failsafe-restore" || uci.get("trafira.settings.dont_touch_dhcp") != "0") exit(2);
fs.writefile(getenv("DNS_LOADER_PROBE"), "loaded\n");
exit(getenv("DNS_RESTORE_FAIL") == "1" ? 1 : 0);
EOF

printf '105 trafira\n200 custom\n' >"$TRAFIRA_RT_TABLES"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/package.uc" prerm upgrade || {
  echo 'FAIL: package upgrade cannot load the DNS restore module' >&2
  exit 1
}
test -s "$DNS_LOADER_PROBE"
test -s "$TRAFIRA_PACKAGE_UPGRADE_STATE"
grep -Fxq '200 custom' "$TRAFIRA_RT_TABLES"
if grep -Fq '105 trafira' "$TRAFIRA_RT_TABLES"; then exit 1; fi

# A real DNS restore failure must still fail preparation and preserve the route name.
printf '105 trafira\n' >"$TRAFIRA_RT_TABLES"
if DNS_RESTORE_FAIL=1 ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/package.uc" prerm upgrade; then
  echo 'FAIL: DNS restore failure was swallowed' >&2
  exit 1
fi
grep -Fxq '105 trafira' "$TRAFIRA_RT_TABLES"
printf 'Package DNS loader and restore failure checks passed\n'
