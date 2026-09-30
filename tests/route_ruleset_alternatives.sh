#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[
 {".name":"proxy",".type":"section","enabled":"1","action":"outbound","outbound_json":"{\"type\":\"direct\"}","domain_suffix":["inline.example"],"community_lists":["youtube"],"source_ip_cidr":["192.0.2.0/24"],"ports":["443","8000-8100"],"resolve_real_ip_for_routing":"1"},
 {".name":"blocked",".type":"section","enabled":"1","action":"block","domain_suffix":["blocked.example"],"community_lists":["discord"]},
 {".name":"bypass",".type":"section","enabled":"1","action":"bypass","domain_suffix":["bypass.example"],"community_lists":["github"]}
]}
JSON
for version in 1.13.18 1.14.1; do
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/$version.json" 127.0.0.1 0 1 '' "$version"
done
node - "$WORK_DIR" <<'JS'
const fs = require('fs'), assert = require('assert/strict');
for (const version of ['1.13.18','1.14.1']) {
  const c = JSON.parse(fs.readFileSync(`${process.argv[2]}/${version}.json`));
  const rules = c.route.rules;
  for (const [domain, action, outbound] of [['inline.example','route','proxy-out'],['blocked.example','reject',null],['bypass.example','route','bypass-out']]) {
    const i = rules.findIndex(r => r.action === action && r.domain_suffix?.includes(domain));
    assert(i >= 0, `${version}: inline route exists for ${domain}`);
    assert(!rules[i].rule_set, `${version}: inline and rule-set alternatives must not be intersected`);
    const list = rules.slice(i+1).find(r => r.action === action && (outbound == null || r.outbound === outbound) && r.rule_set);
    assert(list, `${version}: independent list route for ${domain}`);
    assert(!list.domain_suffix && !list.ip_cidr, 'list match cannot inherit inline destination restrictions');
    if (domain === 'inline.example') {
      for (const r of [rules[i],list]) {
        assert.deepEqual(r.source_ip_cidr,['192.0.2.0/24']);
        assert.deepEqual(r.port,[443]);
        assert.deepEqual(r.port_range,['8000:8100']);
        const previous = rules[rules.indexOf(r)-1];
        assert.equal(previous.action,'resolve','each alternative resolves immediately before its route');
        assert.deepEqual(previous.source_ip_cidr,r.source_ip_cidr);
        assert.deepEqual(previous.rule_set,r.rule_set);
        assert.deepEqual(previous.domain_suffix,r.domain_suffix);
      }
      assert(rules.indexOf(list) < rules.findIndex(r => r.action === 'reject' && r.domain_suffix?.includes('blocked.example')), 'section priority remains intact');
    }
  }
}
JS
printf 'route rule-set alternative checks passed\n'
