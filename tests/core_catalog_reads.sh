#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
catalog_pid=''
cleanup() {
 touch "$WORK_DIR/release"
 [ -z "$catalog_pid" ] || wait "$catalog_pid" || true
 rm -rf "$WORK_DIR"
}
trap cleanup EXIT
cp -R "${TRAFIRA_TEST_LIB_SOURCE:-$ROOT_DIR/trafira/files/usr/lib}" "$WORK_DIR/lib"
if [ -n "${TRAFIRA_TEST_CORE_CLI:-}" ]; then cp "$TRAFIRA_TEST_CORE_CLI" "$WORK_DIR/lib/components/core_cli.uc"; fi
export TRAFIRA_LIB="$WORK_DIR/lib" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" CORE_READ_TEST="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$TRAFIRA_LIB/components/core_sources.uc" <<'UC'
return {environment:()=>({variant:"stable"}),current_version:()=>"1.14.1",fetch:()=>[],installed_version:()=>"1.14.1"};
UC
cat >"$TRAFIRA_LIB/components/core_pin.uc" <<'UC'
return {request_valid:()=>true,read:()=>null,pin_installed:()=>{
 let locks=require("service.operation_lock");
 assert(!locks.acquire("unrelated-writer",false),"pin must retain its exclusive write lock");
 return {success:true};
}};
UC
cat >"$TRAFIRA_LIB/components/core_catalog.uc" <<'UC'
let fs=require("fs"),root=getenv("CORE_READ_TEST");
return {load:()=>{
 fs.writefile(root+"/ready","ready");
 assert(system("while [ ! -f \"$CORE_READ_TEST/release\" ]; do sleep 0.05; done",5000)==0,"catalog barrier timed out");
 return {success:true,entries:[]};
}};
UC
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/core_cli.uc" action '{"action":"catalog"}' >"$WORK_DIR/catalog.json" &
catalog_pid=$!
for _ in $(seq 1 50); do [ ! -f "$WORK_DIR/ready" ] || break; sleep 0.05; done
test -f "$WORK_DIR/ready"
ucode -L "$TRAFIRA_LIB" -e '
let locks=require("service.operation_lock"),read=locks.acquire_read();
assert(read,"gaming catalog reader must coexist with core version discovery");
assert(!locks.acquire("writer",false),"configuration writes must remain excluded while catalogs read");
locks.release(read);
'
# Fetching a remote catalog is not a configuration transaction. Pins may proceed,
# but their own transaction must still exclude competing writers (checked above).
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/components/core_cli.uc" action '{"action":"pin","expected_current_version":"1.14.1"}' >"$WORK_DIR/pin.json"
ucode -e 'let r=json(require("fs").readfile(ARGV[0]));assert(r.success,"remote catalog fetch must not block a pin");' "$WORK_DIR/pin.json"
touch "$WORK_DIR/release"
wait "$catalog_pid"; catalog_pid=''
ucode -e 'assert(json(require("fs").readfile(ARGV[0])).success,"catalog failed");' "$WORK_DIR/catalog.json"
ucode -L "$TRAFIRA_LIB" -e 'let l=require("service.operation_lock"),w=l.acquire("writer",false);assert(w,"catalog must release its read lock");l.release(w);'
echo 'core catalog concurrent read checks passed'
