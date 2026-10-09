#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_type":"doh","dns_server":"https://1.1.1.1/dns-query","service_listen_address":"127.0.0.1"},"section":[{".name":"vpn",".type":"section","action":"connection","enabled":"1","selector_proxy_links":["socks5://127.0.0.1:1080#Test"],"failure_policy":"block","domain_suffix":["example.test"],"fully_routed_ips":["192.0.2.1/32","2001:db8::1/128"],"mixed_proxy_enabled":"1","mixed_proxy_port":"18000"}]}
JSON
mkdir -p "$WORK_DIR/config.json.section-cache"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/trafira/files/usr/lib/singbox/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1 0 1 '' 1.14.1
node - "$WORK_DIR/config.json" <<'NODE'
const fs=require('fs'),assert=require('assert/strict'),path=process.argv[2];
const config=JSON.parse(fs.readFileSync(path));
assert(!config.route.rules.some(r=>r.outbound==='vpn-out'),'cold strict policy must not expose protected outbound');
assert(config.route.rules.some(r=>r.action==='reject' && r.inbound==='vpn-mixed-in'),'mixed listener is protected');
const snapshot=JSON.parse(fs.readFileSync(path+'.failure-policy.json'));
assert(snapshot.sections[0].failure_policy==='block');
assert(snapshot.config.route.rules.some(r=>r.outbound==='vpn-out'),'private primary baseline retained for recovery');
assert(!JSON.stringify(config).includes('__trafira_origin'));
NODE
