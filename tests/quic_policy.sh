#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\t' "$@" >>"$NFT_LOG"
printf '\n' >>"$NFT_LOG"
SH
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"
for flag in missing 0 1; do
  printf '{"settings":{%s},"section":[]}' "$(if [ "$flag" != missing ]; then printf '"disable_quic":"%s"' "$flag"; fi)" >"$WORK_DIR/input.json"
  export NFT_LOG="$WORK_DIR/$flag.nft"
  ucode -L "$LIB" "$LIB/nft/apply.uc" nft-create-runtime-base-fixture \
    "$WORK_DIR/input.json" TrafiraTable localv4 subnets ports ip_ports interfaces br-lan \
    0x00100000 0x00200000 198.18.0.0/15 1602 0
  ucode -L "$LIB" "$LIB/service/state.uc" nft-signature-body-fixture "$WORK_DIR/input.json" >"$WORK_DIR/$flag.signature"
done
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),dir=process.argv[2];
const read=(flag,suffix)=>fs.readFileSync(`${dir}/${flag}.${suffix}`,'utf8');
assert.equal(read('missing','nft'),read('0','nft'),'default and explicit off preserve interception');
assert.equal(read('missing','signature'),read('0','signature'),'off has no signature migration');
assert.notEqual(read('1','signature'),read('0','signature'),'QUIC switch must rebuild nft rules');
const lines=read('1','nft').trim().split('\n').map(l=>l.trim().split('\t'));
assert(lines.some(a=>a[1]==='chain' && a[4]==='quic_reject' && a[5].includes('hook input priority -1;')),'reject must run in a valid input hook before fw4 accepts');
assert(lines.some(a=>JSON.stringify(a.slice(5))===JSON.stringify(['meta','mark','&','0x00100000','==','0x00100000','udp','dport','443','counter','reject','with','icmpx','type','port-unreachable'])),'reject only selected UDP/443, both IP families, without sniffing');
assert(!read('0','nft').includes('quic_reject'));
JS
ucode -L "$LIB" -e '
let r=require("singbox.route");
let c=r.config({disable_quic:"1"},{});
let rule=filter(c.rules,x=>x.protocol=="quic")[0];
assert(rule && type(rule.inbound)=="array" && index(rule.inbound,"tproxy6-in")>=0,"QUIC fallback must cover IPv6");
assert(rule.no_drop===true,"reject must not silently become drop after bursts");
assert(index(c.rules[0].inbound,"tproxy6-in")>=0,"IPv6 fallback must sniff QUIC on nonstandard ports");
assert(!filter(r.config({disable_quic:"0"},{}).rules,x=>x.protocol=="quic")[0],"disabled policy unchanged");
'
echo 'QUIC policy checks passed'
