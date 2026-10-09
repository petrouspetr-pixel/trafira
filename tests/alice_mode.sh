#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/enabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "alice_mode_enabled": "1",
    "alice_ips": ["192.168.1.10/32", "2001:db8::10/128"],
    "alice_macs": ["aa:bb:cc:dd:ee:ff"],
    "alice_interfaces": ["wg0"],
    "dns_server": ["77.88.8.8"],
    "bootstrap_dns_server": ["77.88.8.8"]
  },
  "section": [{
    ".name": "direct_section",
    ".type": "section",
    "enabled": "1",
    "action": "bypass",
    "fully_routed_ips": ["192.168.1.10/32"]
  }]
}
JSON

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env sh
{
  printf 'nft'
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "${NFT_LOG:?}"
NFT
chmod +x "$WORK_DIR/bin/nft"
cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "${LOGGER_LOG:?}"
LOGGER
chmod +x "$WORK_DIR/bin/logger"
export LOGGER_LOG="$WORK_DIR/logger.log"
export NFT_LOG="$WORK_DIR/nft.log"
export PATH="$WORK_DIR/bin:$PATH"
export BYEDPI_RUNTIME_UID=65533
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-create-runtime-base-fixture \
  "$WORK_DIR/enabled.json" TrafiraTable localv4 trafira_subnets trafira_ports trafira_ip_ports \
  trafira_interfaces br-lan 0x00100000 0x00200000 198.18.0.0/15 1602 0
grep -Fq $'mangle\tiifname\t@trafira_interfaces\tjump\talice_gate' "$NFT_LOG"
grep -Fq $'dns_redirect\tiifname\t@trafira_interfaces\tudp\tdport\t53\tjump\talice_dns_gate' "$NFT_LOG"
grep -Fq $'alice_gate\tiifname\t@trafira_alice_interfaces\treturn' "$NFT_LOG"
grep -Fq $'alice_gate\tether\tsaddr\t@trafira_alice_macs\treturn' "$NFT_LOG"
grep -Fq $'alice_gate\tip\tsaddr\t@trafira_alice_sources\treturn' "$NFT_LOG"
grep -Fq $'alice_gate\tip6\tsaddr\t@trafira_alice_sources6\treturn' "$NFT_LOG"
grep -Fq $'alice_gate\tcounter\taccept' "$NFT_LOG"
grep -Fq $'alice_dns_gate\tmeta\tl4proto\t{\ttcp,\tudp\t}\tcounter\tredirect\tto\t:1604' "$NFT_LOG"
: > "$NFT_LOG"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
  "$WORK_DIR/enabled.json" 1 "" TrafiraTable trafira_subnets trafira_ports trafira_ip_ports trafira_interfaces localv4 0x00100000
grep -Fq $'trafira_alice_sources\t{ 192.168.1.10/32 }' "$NFT_LOG"
grep -Fq $'trafira_alice_sources6\t{ 2001:db8::10/128 }' "$NFT_LOG"
grep -Fq $'trafira_alice_macs\t{ aa:bb:cc:dd:ee:ff }' "$NFT_LOG"
grep -Fq $'trafira_alice_interfaces\t{ "wg0" }' "$NFT_LOG"

ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/validator.uc" \
  validate-runtime-fixture "$WORK_DIR/enabled.json" "{}"
grep -Fq "Alice mode interface 'wg0' is not in source_network_interfaces" "$LOGGER_LOG"
mkdir -p "$WORK_DIR/enabled.config.section-cache" "$WORK_DIR/enabled.config.rulesets"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" \
  generate-config-fixture "$WORK_DIR/enabled.json" "$WORK_DIR/enabled.config" "127.0.0.1"
node - "$WORK_DIR/enabled.config" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert(config.inbounds.some((inbound) => inbound.tag === 'alice-dns-in' && inbound.listen_port === 1604));
assert(config.route.rules[0].inbound.includes('alice-dns-in'));
const dnsHijackIndex = config.route.rules.findIndex((rule) => rule.action === 'hijack-dns');
const aliceRejectIndex = config.route.rules.findIndex((rule) =>
  rule.action === 'reject' && rule.inbound?.includes('alice-dns-in'));
assert(dnsHijackIndex >= 0, 'DNS must be hijacked before the Alice inbound guard');
assert(aliceRejectIndex > dnsHijackIndex, 'non-DNS Alice inbound traffic must be rejected before final routing');
assert(config.dns.rules.some((rule) => rule.inbound === 'alice-dns-in' && rule.server === 'dns-server'));
const aliceDnsIndex = config.dns.rules.findIndex((rule) => rule.inbound === 'alice-dns-in');
const fakeDnsIndex = config.dns.rules.findIndex((rule) => rule.domain?.includes('ip.podkop.fyi'));
assert(aliceDnsIndex < fakeDnsIndex, 'Alice real DNS must precede diagnostic FakeIP rules');
assert(config.route.rules.some((rule) => rule.outbound === 'bypass-out' && rule.source_ip_cidr === '192.168.1.10/32'));
NODE

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const enabled = JSON.parse(fs.readFileSync(path.join(dir, 'enabled.json'), 'utf8'));
const write = (name, mutate) => {
  const data = structuredClone(enabled);
  mutate(data.settings);
  fs.writeFileSync(path.join(dir, name), JSON.stringify(data));
};
write('disabled.json', (settings) => { settings.alice_mode_enabled = '0'; });
write('deny.json', (settings) => { settings.alice_list_mode = 'deny'; });
write('invalid.json', (settings) => { settings.alice_ips = ['192.168.1.999']; });
write('invalid-mac.json', (settings) => { settings.alice_macs = ['aa-bb-cc-dd-ee-ff']; });
write('invalid-interface.json', (settings) => { settings.alice_interfaces = ['wg0;reboot']; });
write('invalid-mode.json', (settings) => { settings.alice_list_mode = 'maybe'; });
write('other-mac.json', (settings) => { settings.alice_macs = ['aa:bb:cc:dd:ee:00']; });
write('other-interface.json', (settings) => { settings.alice_interfaces = ['wg1']; });
NODE
: > "$NFT_LOG"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-create-runtime-base-fixture \
  "$WORK_DIR/disabled.json" TrafiraTable localv4 trafira_subnets trafira_ports trafira_ip_ports \
  trafira_interfaces br-lan 0x00100000 0x00200000 198.18.0.0/15 1602 0
if grep -Fq $'alice_gate' "$NFT_LOG"; then
  printf 'FAIL: disabled Alice mode must not install the source gate\n' >&2
  exit 1
fi
node - "$WORK_DIR/enabled.json" "$WORK_DIR/empty.json" <<'NODE'
const fs = require('fs');
const empty = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
delete empty.settings.alice_ips;
delete empty.settings.alice_macs;
delete empty.settings.alice_interfaces;
fs.writeFileSync(process.argv[3], JSON.stringify(empty));
NODE
: > "$NFT_LOG"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-populate-runtime-sets-fixture \
  "$WORK_DIR/empty.json" 1 "" TrafiraTable trafira_subnets trafira_ports trafira_ip_ports trafira_interfaces localv4 0x00100000
if grep -Fq $'nft\tadd\telement\tinet\tTrafiraTable\ttrafira_alice_' "$NFT_LOG"; then
  printf 'FAIL: empty Alice list must leave allowed-source sets empty\n' >&2
  exit 1
fi
mkdir -p "$WORK_DIR/disabled.config.section-cache" "$WORK_DIR/disabled.config.rulesets"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" \
  generate-config-fixture "$WORK_DIR/disabled.json" "$WORK_DIR/disabled.config" "127.0.0.1"
node - "$WORK_DIR/disabled.config" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert(!config.inbounds.some((inbound) => inbound.tag === 'alice-dns-in'));
assert(!config.dns.rules.some((rule) => rule.inbound === 'alice-dns-in'));
NODE

ENABLED_SING_SIGNATURE="$(ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" sing-box-signature-body-fixture "$WORK_DIR/enabled.json")"
DISABLED_SING_SIGNATURE="$(ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" sing-box-signature-body-fixture "$WORK_DIR/disabled.json")"
[ "$ENABLED_SING_SIGNATURE" != "$DISABLED_SING_SIGNATURE" ] || {
  printf 'FAIL: switching Alice mode must reload sing-box\n' >&2
  exit 1
}
ENABLED_NFT_SIGNATURE="$(ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" nft-signature-body-fixture "$WORK_DIR/enabled.json")"
DISABLED_NFT_SIGNATURE="$(ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" nft-signature-body-fixture "$WORK_DIR/disabled.json")"
[ "$ENABLED_NFT_SIGNATURE" != "$DISABLED_NFT_SIGNATURE" ] || {
  printf 'FAIL: switching Alice mode must rebuild nftables\n' >&2
  exit 1
}
for variant in deny other-mac other-interface; do
  VARIANT_NFT_SIGNATURE="$(ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" nft-signature-body-fixture "$WORK_DIR/$variant.json")"
  [ "$ENABLED_NFT_SIGNATURE" != "$VARIANT_NFT_SIGNATURE" ] || {
    printf 'FAIL: changing Alice %s must rebuild nftables\n' "$variant" >&2
    exit 1
  }
done

: > "$NFT_LOG"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/nft/apply.uc" nft-create-runtime-base-fixture \
  "$WORK_DIR/deny.json" TrafiraTable localv4 trafira_subnets trafira_ports trafira_ip_ports \
  trafira_interfaces br-lan 0x00100000 0x00200000 198.18.0.0/15 1602 0
grep -Fq $'alice_gate\tiifname\t@trafira_alice_interfaces\tcounter\taccept' "$NFT_LOG"
grep -Fq $'alice_dns_gate\tip\tsaddr\t@trafira_alice_sources\tmeta\tl4proto\t{\ttcp,\tudp\t}\tcounter\tredirect\tto\t:1604' "$NFT_LOG"
if grep -Fq $'alice_gate\tcounter\taccept' "$NFT_LOG" || grep -Fq $'alice_gate\tip\tsaddr\t@trafira_alice_sources\treturn' "$NFT_LOG"; then
  printf 'FAIL: deny list must keep unlisted clients on Trafira\n' >&2
  exit 1
fi

if ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/validator.uc" \
  validate-runtime-fixture "$WORK_DIR/invalid.json" "{}" >"$WORK_DIR/invalid.log" 2>&1; then
  printf 'FAIL: invalid Alice IP was accepted\n' >&2
  exit 1
fi
grep -Fq 'Invalid Alice mode device IP or subnet' "$WORK_DIR/invalid.log"
for variant in invalid-mac:'Invalid Alice mode MAC address' invalid-interface:'Invalid Alice mode interface' invalid-mode:'Invalid Alice mode list mode'; do
  fixture="${variant%%:*}"
  message="${variant#*:}"
  if ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/validator.uc" \
    validate-runtime-fixture "$WORK_DIR/$fixture.json" "{}" >"$WORK_DIR/$fixture.log" 2>&1; then
    printf 'FAIL: %s was accepted\n' "$fixture" >&2
    exit 1
  fi
  grep -Fq "$message" "$WORK_DIR/$fixture.log" || {
    printf 'FAIL: %s did not report %s\n' "$fixture" "$message" >&2
    cat "$WORK_DIR/$fixture.log" >&2
    exit 1
  }
done
printf 'Alice mode checks passed\n'
