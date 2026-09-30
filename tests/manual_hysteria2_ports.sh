#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
const links = {
  range:'hysteria2://pw@example.com:443?mport=20000-20100,443&sni=example.com',
  authority:'hy2://pw@[2001:db8::1]:20000-20100,443?sni=example.com',
  single:'hy2://pw@example.com:443?mport=8443',
  invalid:'hy2://pw@example.com:443?mport=20100-20000',
  zero:'hy2://pw@example.com:443?mport=0-443',
  huge:'hy2://pw@example.com:443?mport=65536',
  empty:'hy2://pw@example.com:443?mport=443,',
};
for (const [name, link] of Object.entries(links)) {
  const data = {settings:{'.name':'settings','.type':'settings',dns_server:'1.1.1.1'},
    section:[{'.name':'proxy','.type':'section',enabled:'1',action:'proxy',selector_proxy_links:[link],domain_suffix:['example.org']}]};
  fs.writeFileSync(`${dir}/${name}.json`, JSON.stringify(data));
}
NODE
for name in range authority single; do
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.out" 127.0.0.1 0
done
node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
for (const name of ['range','authority','single']) {
  const config = JSON.parse(fs.readFileSync(`${process.argv[2]}/${name}.out`, 'utf8'));
  const outbound = config.outbounds.find(o => o.type === 'hysteria2');
  assert(outbound, 'manual Hysteria2 outbound missing');
  if (name === 'single') { assert.equal(outbound.server_port, 8443); assert.equal(outbound.server_ports, undefined); }
  else { assert.deepEqual(outbound.server_ports, ['20000:20100','443:443']); assert.equal(outbound.server_port, undefined); }
  assert.equal(outbound.tls.enabled, true);
}
NODE
for name in invalid zero huge empty; do
  if ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.out" 127.0.0.1 0 >"$WORK_DIR/error" 2>&1; then
    printf 'FAIL: invalid Hysteria2 ports accepted: %s\n' "$name" >&2
    exit 1
  fi
  grep -Fq 'manual Hysteria2 proxy link is invalid' "$WORK_DIR/error"
done
printf 'Manual Hysteria2 port hopping checks passed\n'
