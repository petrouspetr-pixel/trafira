#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
holder=''
cleanup() { if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi; rm -rf "$WORK_DIR"; }
trap cleanup EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" HANDOFF_DIR="$WORK_DIR"
LIB="$ROOT_DIR/trafira/files/usr/lib"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$LIB" -e 'let fs=require("fs"),l=require("service.operation_lock"),h=l.acquire_read();assert(h,"reader");fs.writefile(getenv("HANDOFF_DIR")+"/ready","1");system("sleep 0.4");l.release(h);' &
holder=$!
for _ in $(seq 1 50); do [ ! -e "$WORK_DIR/ready" ] || break; sleep 0.02; done
test -e "$WORK_DIR/ready"
ucode -L "$LIB" -e 'let l=require("service.operation_lock"),h=l.acquire_wait("component",false,2);assert(h,"component waits for brief catalog snapshot");l.release(h);'
wait "$holder"; holder=''
ucode -L "$LIB" -e 'let l=require("service.operation_lock"),h=l.acquire("writer");assert(h,"writer");assert(!l.acquire_wait("independent",false,0),"real contention stays exclusive");l.release(h);'
printf 'bounded operation lock handoff checks passed\n'
