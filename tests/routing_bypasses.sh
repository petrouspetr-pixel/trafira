#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env sh
printf '%s\t' "$@" >> "${NFT_LOG:?}"
printf '\n' >> "${NFT_LOG:?}"
NFT
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"
export BYEDPI_RUNTIME_UID=65533

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
const base = {settings: {'.name': 'settings', '.type': 'settings', alice_mode_enabled: '1',
  alice_ips: ['192.168.1.10/32', '2001:db8::10/128']}, section: [
  {'.name': 'blocked', '.type': 'section', enabled: '1', action: 'block', fully_routed_ips: ['192.168.1.10/32']}
]};
for (const [name, flags] of Object.entries({missing: {}, off: {exclude_bittorrent:'0', exclude_wifi_calling:'0'},
  torrent: {exclude_bittorrent:'1'}, wifi: {exclude_wifi_calling:'1'}, both: {exclude_bittorrent:'1',exclude_wifi_calling:'1'}})) {
  fs.writeFileSync(`${dir}/${name}.json`, JSON.stringify({...base, settings:{...base.settings,...flags}}));
}
NODE

for variant in missing off torrent wifi both; do
  mkdir -p "$WORK_DIR/$variant.config.section-cache" "$WORK_DIR/$variant.config.rulesets"
  ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/$variant.json" "$WORK_DIR/$variant.config" 127.0.0.1
  export NFT_LOG="$WORK_DIR/$variant.nft"
  ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-create-runtime-base-fixture \
    "$WORK_DIR/$variant.json" TrafiraTable localv4 trafira_subnets trafira_ports trafira_ip_ports \
    trafira_interfaces br-lan 0x00100000 0x00200000 198.18.0.0/15 1602 0
  for owner in sing-box nft; do
    ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" "$owner-signature-body-fixture" \
      "$WORK_DIR/$variant.json" > "$WORK_DIR/$variant.$owner.signature"
  done
done

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const dir = process.argv[2];
const read = (name, suffix) => fs.readFileSync(`${dir}/${name}.${suffix}`, 'utf8');
const rules = name => JSON.parse(read(name, 'config')).route.rules;
assert.deepEqual(rules('off'), rules('missing'), 'disabled switches preserve routing');
assert.equal(read('off', 'nft'), read('missing', 'nft'), 'disabled switches preserve nft rules');
assert.deepEqual(rules('wifi'), rules('off'), 'Wi-Fi exception belongs only to nft');
for (const variant of ['torrent','both']) {
  const route = rules(variant);
  const index = route.findIndex(r => r.protocol === 'bittorrent');
  assert(index >= 0, 'recognized BitTorrent must have a bypass rule');
  assert.deepEqual(route[index].inbound, ['tproxy-in','tproxy6-in'], 'only intercepted LAN traffic bypasses');
  assert.equal(route[index].action, 'route');
  assert.equal(route[index].outbound, 'bypass-out');
  for (const inbound of route[index].inbound)
    assert(route.slice(0,index).some(r => r.action === 'sniff' && r.inbound.includes(inbound)), 'both IP families must be sniffed');
  assert(route.findIndex(r => r.action === 'hijack-dns') < index, 'DNS safety precedes bypass');
  assert(route.findIndex(r => r.action === 'reject' && r.inbound?.includes('alice-dns-in')) < index, 'Alice DNS guard precedes bypass');
  assert(route.findIndex(r => r.source_ip_cidr) > index, 'torrent override precedes section routes');
}
assert(!rules('off').some(r => r.protocol === 'bittorrent'));
assert.equal(read('torrent','nft'), read('off','nft'), 'torrent option does not change packet interception');
for (const variant of ['wifi','both']) {
  const lines = read(variant,'nft').trim().split('\n').map(s => s.trim().split('\t'));
  const exceptions = lines.filter(a => a.includes('{ 500, 4500 }'));
  assert.equal(exceptions.length, 2, 'one UDP exception for each IP family');
  for (const [family, fake] of [['ip','198.18.0.0/15'],['ip6','fc00::/18']]) {
    const rule = exceptions.find(a => a.includes(family));
    assert(rule, `missing ${family} exception`);
    assert.deepEqual(rule.slice(0,5), ['add','rule','inet','TrafiraTable','mangle']);
    assert.deepEqual(rule.slice(5), ['iifname','@trafira_interfaces',family,'daddr','!=',fake,'udp','dport','{ 500, 4500 }','return']);
    const firstIntercept = lines.findIndex(a => a[4] === 'mangle' && (a.includes('jump') || a.includes('mark')));
    assert(lines.indexOf(rule) < firstIntercept, 'return must precede Alice and section interception');
  }
}
assert(!read('off','nft').includes('{ 500, 4500 }'));
for (const owner of ['sing-box','nft']) {
  assert.equal(read('missing',`${owner}.signature`), read('off',`${owner}.signature`));
  const affects = owner === 'sing-box' ? 'torrent' : 'wifi';
  const unrelated = owner === 'sing-box' ? 'wifi' : 'torrent';
  assert.notEqual(read(affects,`${owner}.signature`), read('off',`${owner}.signature`), `${owner} must reload when its switch changes`);
  assert.equal(read(unrelated,`${owner}.signature`), read('off',`${owner}.signature`), 'unrelated subsystem stays unchanged');
}
NODE
printf 'routing_bypasses: OK\n'
