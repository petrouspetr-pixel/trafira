#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/test.uc" <<'UC'
let fs=require("fs"),queue=require("service.list_queue");
let dir=ARGV[0];
let a=queue.create(dir+"/worker.lock",dir+"/pending"),b=queue.create(dir+"/worker.lock",dir+"/pending");
assert(a.begin(true),"first request owns worker");
assert(!b.begin(true),"second request queues without concurrent worker");
assert(fs.readfile(dir+"/pending")=="1","busy request persisted");
assert(a.next(),"owner drains request after current pass");
assert(!a.next(),"requests coalesce into one extra pass");
assert(!b.begin(true),"late request queues");
let wakes=0;
a.end(()=>{wakes++;return true;});
assert(wakes==1 && fs.readfile(dir+"/pending")=="1","end schedules late request without losing it");
assert(b.begin(true),"next worker owns released lock");
assert(!b.next(),"new owner consumed pending request");
b.end(()=>false);
// A snapshot worker does not consume a list request, but wakes it at release.
assert(a.begin(false),"snapshot shares worker lock");
assert(!b.begin(true),"request during snapshot queued");
a.end(()=>{wakes++;return true;});
assert(wakes==2 && b.begin(true),"snapshot release wakes queued lists");
b.end(()=>false);
print("List update queue checks passed\n");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/test.uc" "$WORK_DIR"

# Exercise the real worker: another update arriving during the first download
# must result in a second pass, without waiting for the daily cron.
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_LIST_UPDATE_PID_FILE="$WORK_DIR/runtime/list.pid"
export QUEUE_TEST_DIR="$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.dns_server=9.9.9.9\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
echo 192.0.2.1
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$QUEUE_TEST_DIR/downloads"
if [ ! -f "$QUEUE_TEST_DIR/triggered" ]; then
    touch "$QUEUE_TEST_DIR/triggered"
    ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/updates.uc" list-update >"$QUEUE_TEST_DIR/queued.log" 2>&1
fi
exit 0
SH
chmod +x "$WORK_DIR/bin/"*
PATH="$WORK_DIR/bin:$PATH" ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/updates.uc" list-update
test "$(wc -l <"$WORK_DIR/downloads")" -eq 2
test ! -e "$TRAFIRA_LIST_UPDATE_PID_FILE.pending"
test ! -e "$TRAFIRA_LIST_UPDATE_PID_FILE"
printf 'List worker coalescing integration passed\n'
