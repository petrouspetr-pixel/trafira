#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$WORK_DIR/shim/components" "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$WORK_DIR/shim/components/core_sources.uc" <<'UC'
let version="1.0";
return {environment:()=>({variant:"extended",architecture:"test",package_type:"apk"}),current_version:()=>version,fetch:()=>{
 let locks=require("service.operation_lock"),lock=locks.acquire("other-action",false);
 assert(lock,"catalog network fetch must not hold configuration lock");
 locks.release(lock);
 if(getenv("CATALOG_CHANGE"))version="2.0";
 return [];
}};
UC
printf 'return {request_valid:()=>true,read:()=>null};\n' >"$WORK_DIR/shim/components/core_pin.uc"
printf 'return {load:(env,refresh,fetch)=>{fetch();return {success:true,entries:[]};}};\n' >"$WORK_DIR/shim/components/core_catalog.uc"
for changed in '' 1; do
  CATALOG_CHANGE="$changed" ucode -L "$WORK_DIR/shim" -L "$ROOT_DIR/trafira/files/usr/lib" \
    "$ROOT_DIR/trafira/files/usr/lib/components/core_cli.uc" action '{"action":"catalog"}' >"$WORK_DIR/result.json"
  node - "$WORK_DIR/result.json" "$changed" <<'JS'
const result=JSON.parse(require('fs').readFileSync(process.argv[2]));
if(process.argv[3]) { if(result.success || result.error!=='conflict')throw Error('changed runtime must invalidate catalog'); }
else if(!result.success || result.current_version!=='1.0')throw Error('catalog unavailable');
JS
done
printf 'catalog fetch lock lifetime and runtime snapshot checks passed\n'
