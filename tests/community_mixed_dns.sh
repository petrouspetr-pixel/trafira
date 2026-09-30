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
node - "$WORK_DIR" <<'JS'
const fs = require('fs'), dir = process.argv[2];
const fixture = JSON.parse(fs.readFileSync(`${dir}/fixture.json`));
fs.writeFileSync(`${dir}/mixed.json`,JSON.stringify({version:3,rules:[{domain_suffix:['local.example']},{ip_cidr:['203.0.113.0/24']}]}));
fs.writeFileSync(`${dir}/mixed.txt`,'local.example\n203.0.113.0/24\n');
fixture.section.push({'.name':'localjson','.type':'section',enabled:'1',action:'block',rule_set:[`${dir}/mixed.json`]});
fixture.section.push({'.name':'localtext','.type':'section',enabled:'1',action:'block',domain_ip_lists:[`${dir}/mixed.txt`]});
fs.writeFileSync(`${dir}/fixture.json`,JSON.stringify(fixture));
JS
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
  for (const set of c.route.rule_set.filter(s => s.type === 'local' && s.format === 'source')) {
    const local = JSON.parse(fs.readFileSync(set.path));
    if (!JSON.stringify(local).includes('ip_cidr')) continue;
    const selections = c.dns.rules.flatMap(visit).filter(r => array(r.rule_set).includes(set.tag));
    assert(selections.length > 0, 'mixed local domain/IP list remains eligible for DNS selection');
    for (const rule of selections) assert.equal(rule.match_response,true,'mixed local list uses modern response matching');
  }
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
  const customIndex = c.dns.rules.findIndex(r => usesMixed(r) && r.match_response && array(r.source_ip_cidr).includes('192.0.2.3/32'));
  assert.equal(c.dns.rules[customIndex-1].server,c.dns.rules[customIndex].server,
    'custom DNS address selection must evaluate its configured resolver, preserving split DNS');
  const bypassProbe = c.dns.rules.findIndex(r => r.action === 'evaluate' && r.server === 'dnsmasq-server' && array(r.source_ip_cidr).includes('192.0.2.2/32'));
  assert(bypassProbe >= 0,'source-aware mixed bypass must query dnsmasq before global DNS');
  const bypassRespond = c.dns.rules[bypassProbe+1];
  assert.equal(bypassRespond.action,'respond','preserve matching dnsmasq local answers');
  assert.equal(bypassRespond.type,'logical');
  assert.equal(bypassRespond.mode,'and');
  assert(bypassRespond.rules.some(r => usesMixed(r) && r.match_response && array(r.source_ip_cidr).includes('192.0.2.2/32')),
    'dnsmasq response must match the mixed list and requested source');
  assert(bypassRespond.rules.some(r => r.match_response && r.invert && array(r.ip_cidr).includes('198.18.0.0/15') && array(r.ip_cidr).includes('fc00::/18')),
    'never return a cached FakeIP answer for a bypass source');
  const bypassFallback = c.dns.rules.findIndex(r => usesMixed(r) && r.match_response && r.server === 'dns-server' && array(r.source_ip_cidr).includes('192.0.2.2/32'));
  assert(bypassFallback > bypassProbe+1,'real DNS fallback follows dnsmasq response matching');
}
JS
printf 'mixed community DNS checks passed\n'
