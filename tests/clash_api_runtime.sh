#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ucode -L "$TRAFIRA_LIB" -e '
let api=require("singbox.clash_api"),fs=require("fs"),p=require("singbox.provenance"),f=require("singbox.failure_store");
let expected=api.config({},"192.0.2.1");
assert(length(keys(expected))==1 && expected.external_controller=="192.0.2.1:9090","LAN controller only");
assert(api.config({},"").external_controller=="127.0.0.1:9090","local fallback");
let config={outbounds:[{type:"direct",tag:"direct-out"}],route:{rules:[]},experimental:{clash_api:{external_controller:"0.0.0.0:9090",external_ui:"/obsolete",external_ui_download_url:"https://invalid.example/",secret:"obsolete"},cache_file:{enabled:true}}};
assert(api.apply(config,{},"192.0.2.1"),"remove stale panel, WAN and credentials");
assert(length(keys(config.experimental.clash_api))==1 && config.experimental.clash_api.external_controller==expected.external_controller,"dashboard API retained");
assert(config.experimental.cache_file.enabled,"unrelated configuration preserved");
assert(!api.apply(config,{},"192.0.2.1"),"idempotent");
let path=ARGV[0];fs.writefile(path,sprintf("%J",config));
assert(p.save(path,p.extract(config)),"provenance fixture");
assert(f.save_base(path,config,[{".name":"main",action:"connection",failure_policy:"block"}]),"failure baseline");
assert(api.reconcile(path,{},"192.0.2.2"),"publication reconciliation");
assert(p.load(path)!=null,"provenance preserved");
assert(f.load(path).config.experimental.clash_api.external_controller=="192.0.2.2:9090","failure baseline synchronized");
' "$WORK_DIR/config.json"
printf 'Local API generation, obsolete panel removal, idempotence and metadata passed\n'
ucode -e 'require("fs").writefile(ARGV[0],sprintf("%J",{settings:{".name":"settings",".type":"settings",dns_type:"udp",dns_server:["77.88.8.8"]},section:[{".name":"bypass",".type":"section",action:"bypass",enabled:"1"}]}));' "$WORK_DIR/fixture.json"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/generated.json" 192.0.2.1 0 1 '' 1.14.1 check-only
ucode -e 'let config=json(require("fs").readfile(ARGV[0])),api=config.experimental.clash_api;assert(length(keys(api))==1 && api.external_controller=="192.0.2.1:9090","generated configuration retains only local API");' "$WORK_DIR/generated.json"
