#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$TRAFIRA_TEST_CORE_SERVICE_JSON"
SH
chmod +x "$WORK_DIR/ubus"
export PATH="$WORK_DIR:$PATH"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
identity() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/ui.uc" sing-box-instance-id; }
export TRAFIRA_TEST_CORE_SERVICE_JSON="{\"sing-box\":{\"instances\":{\"main\":{\"running\":true,\"pid\":$$}}}}"
value="$(identity)"
expected="$(awk '{print $1 ":" $22}' "/proc/$$/stat")"
[ "$value" = "$expected" ] || { echo 'Missing process start identity'; exit 1; }
[ "$value" = "$(identity)" ] || { echo 'Process identity is unstable'; exit 1; }
for data in '{}' 'not json' '{"sing-box":{"instances":{"main":{"running":false,"pid":1}}}}' '{"sing-box":{"instances":{"main":{"running":true,"pid":"invalid"}}}}' '{"sing-box":{"instances":{"main":{"running":true,"pid":99999999}}}}'; do
 export TRAFIRA_TEST_CORE_SERVICE_JSON="$data"
 [ -z "$(identity)" ] || { echo 'Invalid or absent core received an identity'; exit 1; }
done
printf 'Core process identity checks passed\n'
