#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_CONFIG_FILE="$WORK_DIR/config"
export PROFILE_APPLY_FIXTURE_DIR="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/tests/fixtures/config_profile_apply.uc"
test "$(stat -c %a "$TRAFIRA_TRANSACTION_DIR")" = 700
# Simulate process death in the small window after the atomic replacement.
printf original >"$TRAFIRA_CONFIG_FILE"
set +e
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),t=require("service.config_transaction"),h=require("singbox.provenance");
let candidate=getenv("PROFILE_APPLY_FIXTURE_DIR")+"/candidate";
fs.writefile(candidate,"candidate");
t.apply(candidate,h.hash_file(getenv("TRAFIRA_CONFIG_FILE")),"test",{
  validate:()=>true,capture:()=>({running:true,enabled:true}),
  activate:()=>{exit(79);},restore:()=>true
});'
status=$?
set -e
test "$status" = 79
test "$(cat "$TRAFIRA_CONFIG_FILE")" = candidate
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e 'let t=require("service.config_transaction");assert(t.recover().success,"unfinished transaction recovers on next process");'
test "$(cat "$TRAFIRA_CONFIG_FILE")" = original
printf 'configuration transaction checks passed\n'
