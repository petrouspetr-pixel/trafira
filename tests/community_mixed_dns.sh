#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[
 {".name":"proxy",".type":"section","enabled":"1","action":"outbound","outbound_json":"{\"type\":\"direct\"}","community_lists":["discord"],"source_ip_cidr":["192.0.2.1/32"]},
 {".name":"bypass",".type":"section","enabled":"1","action":"bypass","community_lists":["discord"],"source_ip_cidr":["192.0.2.2/32"]},
 {".name":"customdns",".type":"section","enabled":"1","action":"dns","dns_server":"9.9.9.9","dns_type":"udp","community_lists":["discord"],"source_ip_cidr":["192.0.2.3/32"]},
 {".name":"builtin",".type":"section","enabled":"1","action":"block","rule_set":["discord"]}
]}
JSON
for version in 1.13.18 1.14.1 1.16.0; do
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/$version.json" 127.0.0.1 0 1 '' "$version"
done
node - "$WORK_DIR" <<'JS'
const fs = require('fs'), assert = require('assert/strict');
const array = v => Array.isArray(v) ? v : v == null ? [] : [v];
for (const version of ['1.13.18','1.14.1','1.16.0']) {
  const c = JSON.parse(fs.readFileSync(`${process.argv[2]}/${version}.json`));
  const tags = c.route.rule_set.filter(s => s.url?.endsWith('/discord.srs')).map(s => s.tag);
  assert(tags.length >= 3);
  const visit = r => [r,...(r.rules || []).flatMap(visit)];
  const usesMixed = r => array(r.rule_set).some(t => tags.includes(t));
  if (version === '1.13.18') {
    assert(c.dns.rules.flatMap(visit).some(usesMixed), 'old DNS selection remains available');
    assert(!c.dns.rules.flatMap(visit).some(r => r.match_response || r.action === 'evaluate'), 'old core receives no modern fields');
    continue;
  }
  for (const rule of c.dns.rules.flatMap(visit).filter(usesMixed))
    assert.equal(rule.match_response,true,`${version}: mixed address sets require response matching`);
  for (const [source,server] of [['192.0.2.1/32','fakeip-server'],['192.0.2.2/32','dns-server']]) {
    const i = c.dns.rules.findIndex(r => usesMixed(r) && array(r.source_ip_cidr).includes(source));
    assert(i > 0,`${version}: source-scoped response route`);
    assert.equal(c.dns.rules[i].server,server,'FakeIP/proxy and real bypass destinations preserved');
    assert.equal(c.dns.rules[i-1].action,'evaluate');
    assert.equal(c.dns.rules[i-1].server,'dns-server','evaluate real addresses, never FakeIP');
    assert.deepEqual(c.dns.rules[i-1].source_ip_cidr,c.dns.rules[i].source_ip_cidr);
    assert.deepEqual(c.dns.rules[i-1].inbound,c.dns.rules[i].inbound);
  }
  assert(c.dns.rules.some(r => usesMixed(r) && r.match_response && array(r.source_ip_cidr).includes('192.0.2.3/32')), 'custom DNS actions handle mixed community lists');
}
JS
printf 'mixed community DNS checks passed\n'
