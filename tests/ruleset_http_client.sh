#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
for (const proxy of [false, true]) {
  const data = {settings: {'.name':'settings', '.type':'settings', dns_server:'1.1.1.1', bootstrap_dns_server:'1.1.1.1',
    download_lists_via_proxy: proxy ? '1' : '0', download_lists_via_proxy_section:'proxy'},
    section:[{'.name':'proxy', '.type':'section', enabled:'1', action:'outbound',
      outbound_json:JSON.stringify({type:'socks',server:'127.0.0.1',server_port:1080}),
      community_lists:['discord'], rule_set:['https://example.com/rules.srs'], domain_suffix:['example.org']}]};
  fs.writeFileSync(`${dir}/${proxy}.json`, JSON.stringify(data));
}
NODE
for version in 1.13.21 1.14.1 1.16.0 unknown; do
  for proxy in false true; do
    output="$WORK_DIR/$version-$proxy.json"
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
      "$WORK_DIR/$proxy.json" "$output" 127.0.0.1 0 1 '' "${version/unknown/}"
    node - "$output" "$version" "$proxy" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const [file, version, proxy] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(file, 'utf8'));
const modern = ['1.14.1','1.16.0'].includes(version);
const remote = config.route.rule_set.filter(r => r.type === 'remote');
assert(remote.length >= 2);
for (const rule of remote) {
  if (modern) {
    assert(rule.http_client && typeof rule.http_client === 'object', 'remote rule-set needs explicit HTTP client');
    assert.equal(rule.download_detour, undefined);
    if (proxy === 'true') assert.equal(rule.http_client.detour, 'proxy-out');
    else assert.equal(rule.http_client.detour, undefined, 'direct download must not detour through bare direct outbound');
  } else {
    assert.equal(rule.http_client, undefined);
    assert.equal(rule.download_detour, proxy === 'true' ? 'proxy-out' : undefined);
  }
}
NODE
  done
done
printf 'Rule-set HTTP client compatibility checks passed\n'
