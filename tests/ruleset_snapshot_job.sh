#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UI_STATE_DIR="$WORK_DIR/ui"
export TRAFIRA_LIST_UPDATE_PID_FILE="$WORK_DIR/list.pid"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_UI_SING_BOX_BIN_PATH="$WORK_DIR/bin/sing-box"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'sing-box version 1.14.2'; exit 0; fi
cp "$3" "$5"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TRAFIRA_RUNTIME_STATE_DIR/curl.log"
sleep 3
exit 28
SH
chmod +x "$WORK_DIR/bin/sing-box" "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/config.json" <<'JSON'
{"route":{"rule_set":[{"type":"remote","tag":"private-list","url":"https://user:secret@example.org/list?token=secret","http_client":{"detour":"selected-proxy"}}]}}
JSON
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\ntrafira.settings.download_lists_via_proxy=1\ntrafira.settings.download_lists_via_proxy_section=proxy\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
run() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/updates.uc" "$@"; }
run ruleset-snapshot-report >"$WORK_DIR/report.json"
node - "$WORK_DIR/report.json" <<'JS'
const fs=require('fs'), r=JSON.parse(fs.readFileSync(process.argv[2]));
if (!r.supported || !r.available || r.entries[0].present || JSON.stringify(r).includes('secret')) throw Error('missing/privacy report');
JS
# A live list owner prevents the snapshot worker from performing network work.
cat >"$WORK_DIR/hold.uc" <<'UC'
let fs = require("fs");
let lock = fs.open(getenv("TRAFIRA_LIST_UPDATE_PID_FILE") + ".lock", "ae");
if (!lock || !lock.lock("xn")) exit(1);
fs.writefile(getenv("TRAFIRA_RUNTIME_STATE_DIR") + "/locked", "1");
system("sleep 10");
UC
ucode "$WORK_DIR/hold.uc" &
lock_pid=$!
for _ in $(seq 1 30); do
  [ ! -e "$TRAFIRA_RUNTIME_STATE_DIR/locked" ] || break
  sleep 0.1
done
test -e "$TRAFIRA_RUNTIME_STATE_DIR/locked"
printf '{"running":true,"started_at":0}' >"$TRAFIRA_RUNTIME_STATE_DIR/snapshot-job.json"
if run ruleset-snapshot-prepare-worker; then echo 'worker ignored list lock' >&2; exit 1; fi
[ ! -e "$TRAFIRA_RUNTIME_STATE_DIR/curl.log" ]
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true
# Kernel lock is released on death, while the stable lock inode stays in place.
test -f "$TRAFIRA_LIST_UPDATE_PID_FILE.lock"
run ruleset-snapshot-prepare-async >"$WORK_DIR/start.json"
run ruleset-snapshot-prepare-async >"$WORK_DIR/duplicate.json"
node - "$WORK_DIR/start.json" "$WORK_DIR/duplicate.json" <<'JS'
const fs=require('fs');
if (!JSON.parse(fs.readFileSync(process.argv[2])).success || JSON.parse(fs.readFileSync(process.argv[3])).success) throw Error('duplicate job accepted');
JS
for _ in $(seq 1 30); do
  run ruleset-snapshot-report >"$WORK_DIR/report.json"
  if node - "$WORK_DIR/report.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2])); process.exit(r.job?.running ? 1 : 0);
JS
  then break; fi
  sleep 1
done
node - "$WORK_DIR/report.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2]));
if (!r.job || r.job.running || r.job.success) throw Error('download failure was not retained');
JS
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/curl.log")" -eq 1
grep -q -- '--proxy http://127.0.0.1:4534 --noproxy' "$TRAFIRA_RUNTIME_STATE_DIR/curl.log"
printf '{"running":true,"pid":"99999999","started_at":1}' >"$TRAFIRA_RUNTIME_STATE_DIR/snapshot-job.json"
run ruleset-snapshot-report >"$WORK_DIR/report.json"
node - "$WORK_DIR/report.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2]));
if (r.job.running || r.job.success || !r.job.message.includes('unexpectedly')) throw Error('dead worker not recovered');
JS
cat >"$WORK_DIR/config.json" <<'JSON'
{"route":{"rule_set":[{"type":"remote","tag":"legacy-list","url":"https://example.org/list","download_detour":"selected-proxy"}]}}
JSON
run ruleset-snapshot-report >"$WORK_DIR/report.json"
run ruleset-snapshot-prepare-async >"$WORK_DIR/legacy-start.json"
node - "$WORK_DIR/report.json" "$WORK_DIR/legacy-start.json" <<'JS'
const fs=require('fs'), r=JSON.parse(fs.readFileSync(process.argv[2]));
if (!r.supported || !r.available || r.preparable || JSON.parse(fs.readFileSync(process.argv[3])).success) throw Error('legacy configuration accepted on modern core');
JS
printf '{"running":true,"started_at":0}' >"$TRAFIRA_RUNTIME_STATE_DIR/snapshot-job.json"
if run ruleset-snapshot-prepare-worker; then echo 'legacy config falsely completed preparation' >&2; exit 1; fi
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/curl.log")" -eq 1
echo 'Snapshot job checks passed'
