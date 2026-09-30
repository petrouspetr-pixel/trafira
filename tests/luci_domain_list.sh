#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-trafira/htdocs/luci-static/resources/view/trafira/section.js" <<'NODE'
const fs = require('fs');
const assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
const main = { parseValueList: value => value.split(/[\s,]+/).filter(Boolean) };
const UCI_PACKAGE = 'trafira';
let values = {};
const uci = {get: (pkg, section, key) => values[key]};
const getConfigListValues = (section, key) => Array.isArray(values[key]) ? values[key] : main.parseValueList(values[key] || '');
function extract(name, next) {
  const start = source.indexOf(`function ${name}(`);
  const end = source.indexOf(`function ${next}(`, start);
  assert(start >= 0 && end > start, `missing function ${name}`);
  return eval(`(${source.slice(start, end).trim()})`);
}
const uniqueDomainTextValues = extract('uniqueDomainTextValues', 'appendUniqueDomainTextValues');
const appendUniqueDomainTextValues = extract('appendUniqueDomainTextValues', 'loadCombinedDomainText');
assert.strictEqual(appendUniqueDomainTextValues(['example.com', 'example.org'], []), 'example.com\nexample.org');
assert.strictEqual(appendUniqueDomainTextValues('example.com\n\nexample.org\n', []), 'example.com\n\nexample.org\n');
assert.strictEqual(appendUniqueDomainTextValues(['EXAMPLE.com'], ['example.com', 'example.org']), 'EXAMPLE.com\nexample.org');
assert.strictEqual(appendUniqueDomainTextValues(null, ['example.com']), 'example.com');
const domainValuesWithPrefix = extract('domainValuesWithPrefix', 'domainTextValuesWithPrefix');
const domainTextValuesWithPrefix = extract('domainTextValuesWithPrefix', 'uniqueDomainTextValues');
const loadCombinedDomainText = extract('loadCombinedDomainText', 'analyzeIpCidrText');
values = {domain: ['exact.example'], domain_suffix: ['suffix.example']};
assert.strictEqual(loadCombinedDomainText('section'), 'full:exact.example\nsuffix.example', 'UCI list domain must keep exact-match semantics');
values = {domain:'suffix.example\nfull:exact.example'};
assert.strictEqual(loadCombinedDomainText('section'), values.domain, 'existing combined text must remain unchanged');
values = {domain:['exact.example'], domain_suffix_text:'legacy.example'};
assert.strictEqual(loadCombinedDomainText('section'), 'legacy.example\nfull:exact.example');
console.log('LuCI UCI domain list checks passed');
NODE
