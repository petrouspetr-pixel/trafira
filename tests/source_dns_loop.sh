#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
for (const source of [false, true]) {
  for (const alice of [false, true]) {
    const section = {'.name':'selected','.type':'section',enabled:'1',action:'bypass',domain_suffix:['example.com']};
    if (source) section.source_ip_cidr = ['192.0.2.10/32'];
    const fixture = {settings:{dns_server:'1.1.1.1',exclude_bittorrent:'1',alice_mode_enabled:alice?'1':'0'},section:[section]};
    fs.writeFileSync(`${process.argv[2]}/${source}-${alice}.fixture.json`,JSON.stringify(fixture));
  }
}
JS
for source in false true; do
  for alice in false true; do
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
      "$WORK_DIR/$source-$alice.fixture.json" "$WORK_DIR/$source-$alice.json" 127.0.0.1 0 1 '' 1.14.1
  done
done
node - "$WORK_DIR" <<'JS'
const fs = require('fs'), assert = require('assert/strict');
const array = v => Array.isArray(v) ? v : v == null ? [] : [v];
for (const source of [false,true]) {
  for (const alice of [false,true]) {
    const config = JSON.parse(fs.readFileSync(`${process.argv[2]}/${source}-${alice}.json`));
    const rules = config.route.rules;
    const hijack = rules.findIndex(r => r.action === 'hijack-dns');
    const firstRoute = rules.findIndex(r => r.action === 'route');
    assert(hijack >= 0 && firstRoute > hijack,'DNS hijacking precedes routing');
    for (const [tag,enabled] of [['source-dns-in',source],['alice-dns-in',alice]]) {
      assert.equal(config.inbounds.some(r => r.tag === tag),enabled,`${tag}: listener presence`);
      const guards = rules.map((rule,index) => ({rule,index})).filter(({rule}) => rule.action === 'reject' && array(rule.inbound).includes(tag));
      assert.equal(guards.length,enabled ? 1 : 0,`${tag}: exactly one guard iff enabled`);
      if (!enabled) continue;
      const {rule:guard,index} = guards[0];
      assert(index > hijack && index < firstRoute,`${tag}: guard follows DNS hijack and precedes all routes`);
      assert.deepEqual(Object.keys(guard).sort(),['action','inbound'],`${tag}: guard rejects every non-DNS payload without extra conditions`);
      assert(rules.some(r => r.action === 'sniff' && array(r.inbound).includes(tag)),`${tag}: DNS protocol detection remains enabled`);
      // Walk the generated terminal rules for DNS and non-DNS payloads on both transports.
      for (const network of ['tcp','udp']) {
        for (const protocol of ['dns','unknown']) {
          const terminal = rules.find(r => {
            if (!['hijack-dns','reject','route'].includes(r.action)) return false;
            if (r.inbound != null && !array(r.inbound).includes(tag)) return false;
            if (r.protocol != null && !array(r.protocol).includes(protocol)) return false;
            if (r.network != null && !array(r.network).includes(network)) return false;
            return true;
          });
          assert.equal(terminal?.action,protocol === 'dns' ? 'hijack-dns' : 'reject',`${tag} ${network} ${protocol}: no route back to listener`);
        }
      }
    }
  }
}
JS
printf 'source DNS loop guard checks passed\n'
