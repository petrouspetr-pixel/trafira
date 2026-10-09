#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export UPDATES_JOB_DIR="$WORK_DIR/jobs"
export CORE_WORKER_TEST="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$TRAFIRA_LIB/components/action.uc" <<'UC'
let fs=require("fs"),locks=require("service.operation_lock");
assert(ARGV[0]=="component-version-action","dedicated internal entrypoint");
assert(fs.stat(ARGV[1]).mode%512==384,"worker request private");
let request=json(fs.readfile(ARGV[1]));
assert(request.pin===true && request.expected_current_version=="1.14.2","structured request preserved");
assert(!locks.acquire("must-not-own",false),"independent worker holds the operation lock");
system("sleep 2");
print("{\"success\":false,\"restored\":true,\"error\":\"candidate_check_failed\"}\n");
UC
call() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/updates.uc" "$@"; }
request='{"action":"install","candidate_id":"stable~aarch64~apk~1.14.1","expected_current_version":"1.14.2","pin":true}'
call component-version-async "$request" >"$WORK_DIR/start.json"
call component-version-async "$request" >"$WORK_DIR/duplicate.json" || true
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),p=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${p}/${n}.json`));
if (!read('start').success || !read('start').job_id || read('duplicate').success) throw Error('duplicate background job');
JS
for _ in $(seq 1 20); do
  call component-version-status >"$WORK_DIR/status.json"
  if node - "$WORK_DIR/status.json" <<'JS'
const state=JSON.parse(require('fs').readFileSync(process.argv[2]));process.exit(state.running?1:0);
JS
  then break; fi
  sleep 1
done
node - "$WORK_DIR/status.json" <<'JS'
const state=JSON.parse(require('fs').readFileSync(process.argv[2]));
if (state.success || state.running || !state.restored || state.error!=='candidate_check_failed') throw Error('worker result after launcher exit');
JS
test -z "$(find "$UPDATES_JOB_DIR" -name '*.core-request' -print)"
printf 'core version worker checks passed\n'
