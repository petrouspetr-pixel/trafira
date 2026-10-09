#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

grep -Fq 'get_alice_devices: [ "diagnostics/alice.uc", "get-alice-devices", 0 ]' "$ROOT_DIR/trafira/files/usr/bin/trafira" || {
  printf 'FAIL: trafira CLI must dispatch get_alice_devices through diagnostics/alice.uc\n' >&2
  exit 1
}

report() {
  ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/alice.uc" get-alice-devices-fixture "$1"
}

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const now = 1790000000;
const base = {
  now,
  settings: {
    alice_mode_enabled: '1',
    alice_list_mode: 'allow',
    source_network_interfaces: ['br-lan', 'wg0'],
    alice_ips: ['192.168.1.10/32', '10.9.0.0/24'],
    alice_macs: ['AA:BB:CC:00:00:02'],
    alice_interfaces: ['wg0', 'awg0', 'br-guest'],
  },
  neigh: [
    { dst: '192.168.1.10', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:01', state: ['REACHABLE'] },
    { dst: 'fe80::1', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:01', state: ['STALE'] },
    { dst: '2001:db8::10', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:01', state: ['STALE'] },
    { dst: '192.168.1.20', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:02', state: ['STALE'] },
    { dst: '192.168.1.30', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:03', state: ['DELAY'] },
    { dst: '192.168.1.40', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:04', state: ['FAILED'] },
    { dst: '192.168.2.50', dev: 'br-guest', lladdr: 'aa:bb:cc:00:00:05', state: ['REACHABLE'] },
    { dst: '203.0.113.1', dev: 'wan', lladdr: 'aa:bb:cc:00:00:06', state: ['REACHABLE'] },
    { dst: 'fe80::7', dev: 'br-lan', lladdr: 'aa:bb:cc:00:00:07', state: ['REACHABLE'] },
  ],
  leases: [
    `${now + 3600} aa:bb:cc:00:00:01 192.168.1.10 iphone 01:aa`,
    `${now + 3600} aa:bb:cc:00:00:03 192.168.1.30 * 01:cc`,
  ].join('\n'),
  wg_dump: [
    'wg0\tprivate\tpublic\t51820\toff',
    `wg0\tpeer-laptop\t(none)\t203.0.113.5:4444\t10.8.0.2/32\t${now - 30}\t100\t200\toff`,
    'wg0\tpeer-phone\t(none)\t(none)\t10.8.0.3/32,fd00:8::3/128\t0\t0\t0\toff',
    'wg1\tprivate\tpublic\t51821\toff',
    `wg1\tpeer-site\t(none)\t198.51.100.7:51821\t10.9.0.0/24\t${now - 600}\t1\t1\t25`,
    `wg1\tpeer-upstream\t(none)\t198.51.100.8:51820\t0.0.0.0/0,::/0\t${now - 5}\t1\t1\t25`,
  ].join('\n'),
  wireguard_peers: [
    { '.type': 'wireguard_wg0', public_key: 'peer-laptop', description: 'Laptop' },
    { '.type': 'wireguard_wg0', public_key: 'peer-phone', description: '' },
  ],
};
fs.writeFileSync(path.join(dir, 'allow.json'), JSON.stringify(base));
const deny = structuredClone(base);
deny.settings.alice_list_mode = 'deny';
fs.writeFileSync(path.join(dir, 'deny.json'), JSON.stringify(deny));
for (const [name, ips, mode = 'allow'] of [
  ['site-partial', ['10.9.0.42/32']],
  ['site-partial-deny', ['10.9.0.42/32'], 'deny'],
  ['site-covered', ['10.9.0.0/25', '10.9.0.128/25']],
  ['site-unmatched', ['10.10.0.0/24']],
  ['site-v6-partial', ['fd00:9::42/128']],
  ['site-v6-covered', ['fd00:9::/65', 'fd00:9:0:0:8000::/65']],
]) {
  const fixture = structuredClone(base);
  fixture.settings.source_network_interfaces.push('wg1');
  fixture.settings.alice_ips = ips;
  fixture.settings.alice_list_mode = mode;
  if (name.startsWith('site-v6')) fixture.wg_dump = fixture.wg_dump.replace('10.9.0.0/24', 'fd00:9::/64');
  fs.writeFileSync(path.join(dir, name + '.json'), JSON.stringify(fixture));
}
const empty = structuredClone(base);
empty.settings.alice_ips = [];
empty.settings.alice_macs = [];
empty.settings.alice_interfaces = [];
fs.writeFileSync(path.join(dir, 'empty.json'), JSON.stringify(empty));
const hidden = structuredClone(base);
hidden.settings.alice_dashboard_enabled = '0';
fs.writeFileSync(path.join(dir, 'hidden.json'), JSON.stringify(hidden));
const disabled = structuredClone(base);
disabled.settings.alice_mode_enabled = '0';
fs.writeFileSync(path.join(dir, 'disabled.json'), JSON.stringify(disabled));
const neighborFailed = structuredClone(base);
delete neighborFailed.neigh;
neighborFailed.neighbor_result = { ok: false };
fs.writeFileSync(path.join(dir, 'neighbor-failed.json'), JSON.stringify(neighborFailed));
const neighborInvalidJson = structuredClone(base);
delete neighborInvalidJson.neigh;
neighborInvalidJson.neighbor_result = { ok: true, output: '{invalid json' };
fs.writeFileSync(path.join(dir, 'neighbor-invalid-json.json'), JSON.stringify(neighborInvalidJson));
const wireguardFailed = structuredClone(base);
delete wireguardFailed.wg_dump;
wireguardFailed.wireguard_result = { ok: false };
fs.writeFileSync(path.join(dir, 'wireguard-failed.json'), JSON.stringify(wireguardFailed));
const leasesMissing = structuredClone(base);
delete leasesMissing.leases;
leasesMissing.lease_result = { ok: false };
fs.writeFileSync(path.join(dir, 'leases-missing.json'), JSON.stringify(leasesMissing));
const malformed = structuredClone(base);
malformed.neigh.push({ dst: 'not-an-ip', dev: 'br-lan', lladdr: 'aa:bb:cc:dd:ee:ff', state: ['REACHABLE'] });
malformed.wg_dump += '\nwg0\tbroken-peer\t(none)';
malformed.leases += '\nnot a valid lease';
malformed.neighbor_result = { ok: true, output: JSON.stringify(malformed.neigh) };
malformed.wireguard_result = { ok: true, output: malformed.wg_dump };
malformed.lease_result = { ok: true, output: malformed.leases };
delete malformed.neigh;
delete malformed.wg_dump;
delete malformed.leases;
fs.writeFileSync(path.join(dir, 'malformed.json'), JSON.stringify(malformed));
const bothFailed = structuredClone(base);
delete bothFailed.neigh;
delete bothFailed.wg_dump;
bothFailed.neighbor_result = { ok: false };
bothFailed.wireguard_result = { ok: false };
fs.writeFileSync(path.join(dir, 'both-failed.json'), JSON.stringify(bothFailed));
NODE

report "$WORK_DIR/allow.json" >"$WORK_DIR/allow.out"
report "$WORK_DIR/deny.json" >"$WORK_DIR/deny.out"
report "$WORK_DIR/empty.json" >"$WORK_DIR/empty.out"
report "$WORK_DIR/disabled.json" >"$WORK_DIR/disabled.out"
report "$WORK_DIR/hidden.json" >"$WORK_DIR/hidden.out"
report "$WORK_DIR/neighbor-failed.json" >"$WORK_DIR/neighbor-failed.out"
report "$WORK_DIR/wireguard-failed.json" >"$WORK_DIR/wireguard-failed.out"
report "$WORK_DIR/leases-missing.json" >"$WORK_DIR/leases-missing.out"
report "$WORK_DIR/malformed.json" >"$WORK_DIR/malformed.out"
report "$WORK_DIR/both-failed.json" >"$WORK_DIR/both-failed.out"
report "$WORK_DIR/neighbor-invalid-json.json" >"$WORK_DIR/neighbor-invalid-json.out"
for name in site-partial site-partial-deny site-covered site-unmatched site-v6-partial site-v6-covered; do
  report "$WORK_DIR/$name.json" >"$WORK_DIR/$name.out"
done

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const dir = process.argv[2];
const read = (name) => JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
const byKey = (report) => {
  const devices = {};
  for (const device of report.devices) {
    if (device.mac && !devices[device.mac]) devices[device.mac] = device;
    for (const ip of device.ips) devices[ip] = device;
  }
  return devices;
};

const allow = read('allow.out');
assert.equal(allow.enabled, true);
assert.equal(allow.list_mode, 'allow');
assert.equal(allow.dashboard_visible, true, 'the dashboard panel is shown by default');
let devices = byKey(allow);
assert.equal(allow.devices.length, 8, 'LAN addresses sharing a MAC are listed separately; FAILED, uplink, link-local-only neighbours and upstream WireGuard peers are skipped');
assert(!devices['aa:bb:cc:00:00:06'], 'uplink neighbours are not client devices');
assert(!devices['aa:bb:cc:00:00:07'], 'devices without routable addresses are skipped');

const iphone = devices['192.168.1.10'];
assert.equal(iphone.name, 'iphone');
assert.deepEqual(iphone.ips, ['192.168.1.10'], 'each LAN IP is reported separately');
assert.equal(iphone.online, true);
assert.equal(iphone.status, 'trafira', 'the listed IP uses Trafira');
assert.equal(iphone.matched_by, 'ip:192.168.1.10/32');
const iphoneIpv6 = devices['2001:db8::10'];
assert.equal(iphoneIpv6.name, '', 'a lease name is not copied to another IP sharing the MAC');
assert.equal(iphoneIpv6.status, 'direct', 'the unlisted IP bypasses Trafira');

const byMac = devices['aa:bb:cc:00:00:02'];
assert.equal(byMac.matched_by, 'mac:aa:bb:cc:00:00:02');
assert.equal(byMac.online, false);
assert.equal(byMac.status, 'trafira');

const unlisted = devices['aa:bb:cc:00:00:03'];
assert.equal(unlisted.name, '', 'a "*" lease hostname is not a name');
assert.equal(unlisted.matched_by, null);
assert.equal(unlisted.status, 'direct');

assert.equal(devices['aa:bb:cc:00:00:05'].status, 'not_captured', 'Alice-listed interface outside Source Network Interface');

const laptop = devices['10.8.0.2'];
assert.equal(laptop.kind, 'wireguard');
assert.equal(laptop.name, 'Laptop');
assert.equal(laptop.interface, 'wg0');
assert.equal(laptop.online, true);
assert.equal(laptop.matched_by, 'interface:wg0');
assert.equal(laptop.status, 'trafira');

const phone = devices['10.8.0.3'];
assert.deepEqual(phone.ips, ['10.8.0.3', 'fd00:8::3']);
assert.equal(phone.online, false);
assert.equal(phone.last_handshake, null);

const site = devices['10.9.0.0/24'];
assert.equal(site.interface, 'wg1');
assert.equal(site.online, false, 'handshake older than 3 minutes is offline');
assert.equal(site.matched_by, 'ip:10.9.0.0/24');
assert.equal(site.status, 'not_captured', 'wg1 is not a source interface');

assert.deepEqual(allow.warnings, [
  { code: 'interface_not_captured', value: 'awg0' },
  { code: 'interface_not_captured', value: 'br-guest' },
]);

devices = byKey(read('deny.out'));
assert.equal(devices['192.168.1.10'].status, 'direct', 'deny mode bypasses the listed IP');
assert.equal(devices['2001:db8::10'].status, 'trafira', 'deny mode still routes the unlisted IP');
assert.equal(devices['aa:bb:cc:00:00:03'].status, 'trafira');
assert.equal(devices['10.8.0.2'].status, 'direct');
assert.equal(devices['aa:bb:cc:00:00:05'].status, 'not_captured');

for (const name of ['site-partial', 'site-partial-deny']) {
  const peer = byKey(read(name + '.out'))['10.9.0.0/24'];
  assert.equal(peer.status, 'mixed', 'a host inside a peer subnet only partially matches it');
  assert.equal(peer.matched_by, 'ip:10.9.0.42/32');
}
assert.equal(byKey(read('site-covered.out'))['10.9.0.0/24'].status, 'trafira', 'two adjacent subnets together cover the peer');
assert.equal(byKey(read('site-unmatched.out'))['10.9.0.0/24'].status, 'direct');
assert.equal(byKey(read('site-v6-partial.out'))['fd00:9::/64'].status, 'mixed');
assert.equal(byKey(read('site-v6-covered.out'))['fd00:9::/64'].status, 'trafira');

const empty = read('empty.out');
assert(empty.devices.every((device) => device.status !== 'trafira'), 'empty allow list sends everyone direct');
assert.deepEqual(empty.warnings, [{ code: 'empty_allow_list', value: '' }]);

assert.deepEqual(read('disabled.out'), { enabled: false });
assert.equal(read('hidden.out').dashboard_visible, false);

const neighborFailed = read('neighbor-failed.out');
assert(neighborFailed.devices.every((device) => device.kind === 'wireguard'));
assert(neighborFailed.warnings.some((warning) => warning.code === 'neighbor_source_unavailable'));

const neighborInvalidJson = read('neighbor-invalid-json.out');
assert(neighborInvalidJson.devices.every((device) => device.kind === 'wireguard'));
assert(neighborInvalidJson.warnings.some((warning) => warning.code === 'neighbor_source_unavailable'));

const wireguardFailed = read('wireguard-failed.out');
assert(wireguardFailed.devices.every((device) => device.kind === 'lan'));
assert(wireguardFailed.warnings.some((warning) => warning.code === 'wireguard_source_unavailable'));

const leasesMissing = read('leases-missing.out');
assert(leasesMissing.devices.some((device) => device.mac === 'aa:bb:cc:00:00:01' && device.name === ''));
assert(leasesMissing.warnings.some((warning) => warning.code === 'dhcp_source_unavailable'));

const malformed = read('malformed.out');
assert(malformed.warnings.some((warning) => warning.code === 'neighbor_source_partial'));
assert(malformed.warnings.some((warning) => warning.code === 'wireguard_source_partial'));
assert(malformed.warnings.some((warning) => warning.code === 'dhcp_source_partial'));

const bothFailed = read('both-failed.out');
assert.deepEqual(bothFailed.devices, []);
assert(bothFailed.warnings.some((warning) => warning.code === 'neighbor_source_unavailable'));
assert(bothFailed.warnings.some((warning) => warning.code === 'wireguard_source_unavailable'));
NODE

printf 'Alice device report checks passed\n'
