#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_GAMING_CATALOG="$ROOT_DIR/trafira/files/usr/share/trafira/gaming-presets.json"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf original >"$TRAFIRA_CONFIG_FILE"
cat >"$TRAFIRA_LIB/config/profile_runtime.uc" <<'UC'
let fs=require("fs"),format=require("config.profile_format");
return {
 read_document:()=>({success:true,document:{schema:1,name:"Current",config:[{".name":"settings",".type":"settings"},{".name":"vpn",".type":"section",action:"connection",enabled:"1"}]}}),
 prepare:(document,directory)=>{fs.writefile(directory+"/trafira",format.to_uci(document.config));return {success:true,path:directory+"/trafira"};},
 hooks:()=>({validate:()=>true,capture:()=>({running:true,enabled:false}),activate:()=>true,restore:()=>true})
};
UC
cat >"$TRAFIRA_LIB/diagnostics/alice.uc" <<'UC'
print(sprintf("%J",{devices:[{name:"<script>device</script>",interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]}]}));
UC
call(){ ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/gaming_cli.uc" action "$1"; }
call '{"action":"catalog"}' >"$WORK_DIR/catalog.json"
digest=$(sha256sum "$TRAFIRA_CONFIG_FILE" | cut -d' ' -f1)
request="\"preset\":\"steam\",\"device_ips\":[\"192.0.2.5/32\"],\"proxy_section\":\"vpn\",\"placement\":\"before-device-routes\",\"expected_digest\":\"$digest\""
call "{\"action\":\"preview\",$request}" >"$WORK_DIR/preview.json"
test "$(cat "$TRAFIRA_CONFIG_FILE")" = original
call "{\"action\":\"apply\",$request}" >"$WORK_DIR/start.json"
for _ in $(seq 1 15); do
 call '{"action":"status"}' >"$WORK_DIR/status.json"
 if node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1])).running?1:0)' "$WORK_DIR/status.json"; then break; fi
 sleep 1
done
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),root=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${root}/${n}.json`));
if(!read('catalog').success || read('catalog').presets.length!==4)throw Error('catalog');
if(!read('preview').applicable || read('preview').patch.sections.length!==2)throw Error('preview');
if(!read('start').running || !read('status').success || read('status').running)throw Error('durable apply');
JS
grep -q preset_owner "$TRAFIRA_CONFIG_FILE"
test "$(cat "$TRAFIRA_TRANSACTION_DIR/previous.uci")" = original
call "{\"action\":\"apply\",$request}" >"$WORK_DIR/stale.json"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.success||r.error!=="conflict")throw Error("stale preview");' "$WORK_DIR/stale.json"
printf 'gaming transactional application checks passed\n'
