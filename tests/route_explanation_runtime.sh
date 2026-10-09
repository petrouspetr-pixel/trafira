#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
echo unexpected-network >&2
exit 91
SH
chmod +x "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/config.json" <<'JSON'
{"route":{"rules":[{"domain_suffix":"example","action":"route","outbound":"vpn-out"}],"final":"direct-out"},"dns":{"rules":[],"final":"dns-server"},"outbounds":[{"tag":"vpn-out","type":"direct"}]}
JSON
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
run() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/route_explain.uc" explain "$1"; }
before="$(sha256sum "$TRAFIRA_UCI_STATE_FILE")"
run '{"domain":"store.example","source":{"kind":"device","ip":"192.0.2.5"},"port":443,"network":"tcp","protocol":"tls"}' >"$WORK_DIR/good.json"
run '{"domain":"bad;touch /tmp/owned","source":{"kind":"router"},"port":443,"network":"tcp"}' >"$WORK_DIR/bad.json"
run '{"domain":"store.example","source":{"kind":"router"},"port":65536,"network":"tcp"}' >"$WORK_DIR/port.json"
run 'not-json' >"$WORK_DIR/json.json"
run "$(node -e 'process.stdout.write("x".repeat(8193))')" >"$WORK_DIR/large.json"
printf 'trafira.settings.alice_mode_enabled=1\ntrafira.settings.alice_list_mode=allow\ntrafira.settings.alice_ips=198.51.100.5\n' >>"$TRAFIRA_UCI_STATE_FILE"
run '{"domain":"store.example","source":{"kind":"device","ip":"192.0.2.5"},"port":443,"network":"tcp","protocol":"tls"}' >"$WORK_DIR/alice.json"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2];
const read=n=>JSON.parse(fs.readFileSync(`${dir}/${n}.json`));
if (read('good').decision.outbound!=='vpn-out' || !read('good').limitations.includes('provenance_unavailable')) throw Error('route / missing provenance');
for(const n of ['bad','port','json','large']) if(read(n).success) throw Error('accepted '+n);
if(read('alice').decision.status!=='direct') throw Error('Alice bypass must precede sing-box');
if (read('good').dns_query.performed) throw Error('unexpected DNS query');
JS
# CLI did not persist anything; only our explicit Alice test setup changed UCI.
head -n2 "$TRAFIRA_UCI_STATE_FILE" >"$WORK_DIR/original"
test "${before%% *}" = "$(sha256sum "$WORK_DIR/original" | cut -d' ' -f1)"
printf 'route explanation runtime checks passed\n'
