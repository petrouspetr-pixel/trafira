#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
reader_a='' reader_b='' writer_pid=''
cleanup() {
  touch "$WORK_DIR/release-readers" "$WORK_DIR/release-writer"
  for pid in "$reader_a" "$reader_b" "$writer_pid"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib" TRAFIRA_CONFIG_FILE="$WORK_DIR/current"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_GAMING_CATALOG="$ROOT_DIR/trafira/files/usr/share/trafira/gaming-presets.json"
export CATALOG_TEST_DIR="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf original >"$TRAFIRA_CONFIG_FILE"
printf stale-owner >"$TRAFIRA_RUNTIME_STATE_DIR/operation-owner.json"
cat >"$TRAFIRA_LIB/config/profile_runtime.uc" <<'UC'
return {read_document:()=>({success:true,document:{config:[{".name":"settings",".type":"settings"},{".name":"vpn",".type":"section",enabled:"1",action:"connection"}]}})};
UC
cat >"$TRAFIRA_LIB/diagnostics/alice.uc" <<'UC'
let fs=require("fs"),root=getenv("CATALOG_TEST_DIR"),reader=getenv("CATALOG_READER");
fs.writefile(root+"/reader-"+reader,"ready");
assert(system("while [ ! -f \"$CATALOG_TEST_DIR/release-readers\" ]; do sleep 0.05; done",5000)==0,"reader barrier timed out");
print(sprintf("%J",{devices:[]}));
UC
call(){ ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/gaming_cli.uc" action "$1"; }
wait_ready() {
  for _ in $(seq 1 50); do
    [ ! -f "$WORK_DIR/$1" ] || return 0
    sleep 0.05
  done
  echo "$1 did not enter the catalog while another reader was active" >&2
  return 1
}
CATALOG_READER=a call '{"action":"catalog"}' >"$WORK_DIR/a.json" &
reader_a=$!
wait_ready reader-a
CATALOG_READER=b call '{"action":"catalog"}' >"$WORK_DIR/b.json" &
reader_b=$!
wait_ready reader-b
# Catalogs read an isolated, digest-checked file snapshot, not mutable runtime.
ucode -L "$TRAFIRA_LIB" -e 'let l=require("service.operation_lock"),h=l.acquire("writer",false); assert(h,"catalog discovery must not lock configuration writers"); l.release(h);'
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/operation-owner.json"
inode=$(stat -c %i "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock")
touch "$WORK_DIR/release-readers"
wait "$reader_a"; reader_a=''
wait "$reader_b"; reader_b=''
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/operation-owner.json"
node - "$WORK_DIR" <<'JS'
const assert=require('assert'),fs=require('fs'),root=process.argv[2];
for(const name of ['a','b']) {
  const result=JSON.parse(fs.readFileSync(`${root}/${name}.json`));
  assert.equal(result.success,true,`${name}: ${JSON.stringify(result)}`);
  assert.equal(result.presets.length,4);
  assert.equal(result.proxies[0].id,'vpn');
}
JS
cat >"$WORK_DIR/writer.uc" <<'UC'
let fs=require("fs"),locks=require("service.operation_lock"),held=locks.acquire("writer",false);
assert(held,"writer acquires lock after readers finish");
fs.writefile(getenv("CATALOG_TEST_DIR")+"/writer-ready","ready");
assert(system("while [ ! -f \"$CATALOG_TEST_DIR/release-writer\" ]; do sleep 0.05; done",5000)==0,"writer barrier timed out");
locks.release(held);
UC
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/writer.uc" &
writer_pid=$!
wait_ready writer-ready
call '{"action":"catalog"}' >"$WORK_DIR/busy.json"
node - "$WORK_DIR/busy.json" <<'JS'
const assert=require('assert'),fs=require('fs'),r=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(r.success,true,'catalog snapshot remains available during a runtime/list update');
JS
call '{"action":"remove"}' >"$WORK_DIR/mutation.json"
node - "$WORK_DIR/mutation.json" <<'JS'
const assert=require('assert'),fs=require('fs'),r=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(r.success,false);assert.equal(r.error,'busy','mutations must still wait for the writer');
JS
touch "$WORK_DIR/release-writer"
wait "$writer_pid"; writer_pid=''
test "$(stat -c %i "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock")" = "$inode"
test "$(cat "$TRAFIRA_CONFIG_FILE")" = original
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/operation-owner.json"
printf 'gaming catalog concurrent read checks passed\n'
