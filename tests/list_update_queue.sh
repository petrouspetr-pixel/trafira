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
