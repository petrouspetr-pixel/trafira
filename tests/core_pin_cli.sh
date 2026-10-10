#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$WORK_DIR/lib" TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$TRAFIRA_LIB" "$TRAFIRA_RUNTIME_STATE_DIR"
cp -a "$ROOT_DIR/trafira/files/usr/lib/." "$TRAFIRA_LIB/"
printf 'trafira.settings=settings\n' >"$TRAFIRA_UCI_STATE_FILE"
# Keep the real CLI, pin persistence and operation lock; replace only installed
# device facts and make any attempt to launch installation observable.
cat >"$TRAFIRA_LIB/components/core_sources.uc" <<'UC'
return {
 current_version:()=>"1.14.2",environment:()=>({variant:"stable"}),
 installed_version:()=>"1.14.2-r3"
};
UC
cat >"$TRAFIRA_LIB/components/updates.uc" <<'UC'
require("fs").writefile(getenv("TRAFIRA_RUNTIME_STATE_DIR")+"/unexpected-worker","called");
print("{\"success\":false}\n");
UC
run() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/core_cli.uc" action "$1"; }
run '{"action":"pin","expected_current_version":"1.14.2","expected_current_variant":"stable"}' |
  ucode -e 'let r=json(require("fs").readfile("/dev/stdin")); assert(r.success && r.pin.version=="1.14.2-r3","CLI pins installed revision");'
ucode -L "$TRAFIRA_LIB" -e 'assert(require("components.core_pin").read().version=="1.14.2-r3","pin survives another process");'
for request in \
  '{"action":"pin","expected_current_version":"1.14.1","expected_current_variant":"stable"}' \
  '{"action":"pin","expected_current_version":"1.14.2","expected_current_variant":"tiny"}'; do
  run "$request" | ucode -e 'let r=json(require("fs").readfile("/dev/stdin")); assert(!r.success && r.error=="conflict","stale current identity rejected");'
done
run '{"action":"unpin","expected_current_version":"1.14.2"}' |
  ucode -e 'let r=json(require("fs").readfile("/dev/stdin")); assert(r.success && r.pin==null,"CLI unpin");'
ucode -L "$TRAFIRA_LIB" -e 'assert(require("components.core_pin").read()==null,"unpin survives another process");'
[ ! -e "$TRAFIRA_RUNTIME_STATE_DIR/unexpected-worker" ]
printf 'installed core pin CLI checks passed\n'
