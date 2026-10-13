#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
printf 'trafira.settings=settings\ntrafira.settings.source_network_interfaces=br-lan\n' >"$WORK_DIR/uci"
TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/trafira/files/usr/lib/diagnostics/alice.uc" get-known-devices >"$WORK_DIR/report.json"
node - "$WORK_DIR/report.json" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),r=JSON.parse(fs.readFileSync(process.argv[2]));
assert(Array.isArray(r.available_interfaces));assert(r.available_interfaces.includes('lo'),'actual interfaces available when Alice Mode is off');
assert(r.available_interfaces.every(name=>/^[a-zA-Z0-9_.:@-]{1,15}$/.test(name)));
assert(r.source_interfaces.includes('br-lan'),'capture scope unchanged');
JS
printf 'Known-device interface choices checks passed\n'
