#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$WORK_DIR" <<'NODE'
const fs=require('fs'),root=process.argv[2];
const base={settings:{},section:[{'.name':'vpn','.type':'section',action:'connection',enabled:'1',selector_proxy_links:['socks5://127.0.0.1:1080#Test']}]};
for(const mode of ['base','router','policy','threshold']) {
 const value=structuredClone(base);
 if(mode==='router') Object.assign(value.settings,{router_origin_enabled:'1',router_origin_section:'vpn'});
 if(mode==='policy'||mode==='threshold') Object.assign(value.section[0],{failure_policy:'block',failure_threshold:mode==='threshold'?'4':'3'});
 fs.writeFileSync(`${root}/${mode}.json`,JSON.stringify(value));
}
NODE
for mode in base router policy threshold; do
 ucode -L "$LIB" "$LIB/service/state.uc" sing-box-signature-body-fixture "$WORK_DIR/$mode.json" >"$WORK_DIR/$mode.signature"
done
! cmp -s "$WORK_DIR/base.signature" "$WORK_DIR/router.signature" || { echo 'Router setting must reload core'; exit 1; }
! cmp -s "$WORK_DIR/base.signature" "$WORK_DIR/policy.signature" || { echo 'Failure policy must reload core'; exit 1; }
! cmp -s "$WORK_DIR/policy.signature" "$WORK_DIR/threshold.signature" || { echo 'Policy threshold must reload controller'; exit 1; }
mkdir -p "$WORK_DIR/config.section-cache"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/router.json" "$WORK_DIR/config" 127.0.0.1
node - "$WORK_DIR/config" <<'NODE'
const fs=require('fs'),assert=require('assert/strict'),c=JSON.parse(fs.readFileSync(process.argv[2]));
assert(c.inbounds.filter(i=>i.listen_port===1605).length===2);
assert(c.route.rules.some(r=>r.outbound==='vpn-out' && r.inbound.includes('router-tproxy-in')));
NODE
