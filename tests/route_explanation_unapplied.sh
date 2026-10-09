#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib" TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf '{"route":{"rules":[],"final":"vpn-out"},"dns":{"rules":[],"final":"dns-server"}}' >"$WORK_DIR/core.json"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/core.json\ntrafira.settings.alice_mode_enabled=1\ntrafira.settings.alice_list_mode=allow\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/route_explain.uc" explain '{"domain":"example.org","source":{"kind":"device","ip":"192.0.2.5"},"port":443,"network":"tcp"}' >"$WORK_DIR/result"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.decision.status!=="indeterminate")throw Error("Unconfirmed UCI gate masquerades as active capture");' "$WORK_DIR/result"
