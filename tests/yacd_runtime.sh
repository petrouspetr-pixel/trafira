#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2];
for(const enabled of ['0','1']) fs.writeFileSync(`${dir}/fixture-${enabled}.json`,JSON.stringify({settings:{'.name':'settings','.type':'settings',dns_type:'udp',dns_server:['77.88.8.8'],enable_yacd:enabled},section:[{'.name':'bypass','.type':'section',action:'bypass',enabled:'1'}]}));
JS
for enabled in 0 1; do
 ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/fixture-$enabled.json" "$WORK_DIR/generated-$enabled.json" 192.0.2.1 0 1 '' 1.14.1 check-only
 done
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),assert=require('node:assert/strict'),dir=process.argv[2];
const off=JSON.parse(fs.readFileSync(`${dir}/generated-0.json`)).experimental.clash_api;
const on=JSON.parse(fs.readFileSync(`${dir}/generated-1.json`)).experimental.clash_api;
assert.equal(off.external_ui,undefined);
assert.equal(on.external_ui,'/usr/share/sing-box/ui');
assert.match(on.external_ui_download_url,/^https:\/\/github.com\/MetaCubeX\/Yacd-meta\/archive\/[a-f0-9]{40}\.zip$/);
assert.equal(on.external_ui_download_detour,'direct-out');
assert.equal(on.external_controller,'192.0.2.1:9090');
JS
ucode -L "$TRAFIRA_LIB" -e 'let u=require("singbox.clash_ui");let c={outbounds:[{tag:"direct-out"},{tag:"proxy-out"}],experimental:{clash_api:{external_controller:"192.0.2.1:9090"},cache_file:{enabled:true}}};assert(u.apply(c,{enable_yacd:"1"},"192.0.2.1"),"stale API repaired");assert(c.experimental.clash_api.external_ui=="/usr/share/sing-box/ui" && c.experimental.cache_file.enabled,"panel and unrelated fields");assert(!u.apply(c,{enable_yacd:"1"},"192.0.2.1"),"idempotent");assert(u.apply(c,{enable_yacd:"0"},"192.0.2.1") && c.experimental.clash_api.external_ui==null,"disable removes UI");assert(u.config({enable_yacd:"1",download_components_via_proxy:"1",download_components_via_proxy_section:"proxy"},"192.0.2.1").external_ui_download_detour=="proxy-out","selected download section");'
# Actual publication must replace the previously disabled API config.
cp "$WORK_DIR/generated-0.json" "$WORK_DIR/live.json"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/runtime.uc" save-config-file-fixture "$WORK_DIR/generated-1.json" "$WORK_DIR/live.json"
node - "$WORK_DIR/live.json" <<'JS'
const assert=require('node:assert/strict'),config=JSON.parse(require('fs').readFileSync(process.argv[2]));
assert.equal(config.experimental.clash_api.external_ui,'/usr/share/sing-box/ui');
JS
printf 'YACD generation, missing UI download, stale API normalization and publication passed\n'

ucode -L "$TRAFIRA_LIB" -e 'let ui=require("singbox.clash_ui"),p=require("singbox.provenance"),f=require("singbox.failure_store"),fs=require("fs");let path=ARGV[0],config={outbounds:[{type:"direct",tag:"direct-out"}],route:{rules:[]},experimental:{clash_api:{external_controller:"192.0.2.1:9090"}}};fs.writefile(path,sprintf("%J",config));assert(p.save(path,p.extract(config)),"provenance fixture");assert(f.save_base(path,config,[{".name":"main",action:"connection",failure_policy:"block"}]),"failure baseline fixture");assert(ui.reconcile(path,{enable_yacd:"1"},"192.0.2.1"),"reconcile stale config");assert(p.load(path)!=null,"provenance rebound");let base=f.load(path);assert(base!=null && base.config.experimental.clash_api.external_ui=="/usr/share/sing-box/ui","failure baseline retains corrected panel");' "$WORK_DIR/stale.json"
