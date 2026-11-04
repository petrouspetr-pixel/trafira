#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Exercise the backend contract used by LuCI, without DNS/network access.
python3 - "$WORK_DIR" <<'PYFIXTURE'
import base64
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
uuid = "00000000-0000-4000-8000-000000000001"
links = []
for index, protocol in enumerate(["vless", "trojan", "ss", "socks4", "socks4a", "socks5", "hysteria2", "hy2", "vmess"]):
    host = f"_edge_{index}.eu_two_.example.com"
    if protocol == "vmess":
        payload = json.dumps({"add": host, "port": "443", "id": uuid, "ps": protocol}).encode()
        link = "vmess://" + base64.b64encode(payload).decode()
    elif protocol == "vless":
        link = f"vless://{uuid}@{host}:443?encryption=none&security=tls&sni=tls.example.com#{protocol}"
    elif protocol == "ss":
        auth = base64.b64encode(b"aes-128-gcm:password").decode()
        link = f"ss://{auth}@{host}:443#{protocol}"
    else:
        link = f"{protocol}://password@{host}:443#{protocol}"
    links.append(link)
fixture = {"settings": {".name": "settings", ".type": "settings"}, "section": [{
    ".name": "demo", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": links,
}]}
(root / "fixture.json").write_text(json.dumps(fixture))
(root / "links.txt").write_text("\n".join(links) + "\n")
PYFIXTURE

ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/subscription/parser.uc" normalize-uri-list \
  "$WORK_DIR/links.txt" "$WORK_DIR/parsed.json"
mkdir -p "$WORK_DIR/config.json.section-cache"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1

ucode -L "$TRAFIRA_LIB" -e '
let fs = require("fs"), links = require("subscription.share_link");
let parsed = json(fs.readfile(ARGV[0])), config = json(fs.readfile(ARGV[1]));
let exported = [];
for (let source in [parsed, config]) {
    let hosts = {};
    for (let outbound in source.outbounds || []) {
        if (!outbound.server) continue;
        hosts[outbound.server] = true;
        if (outbound.server_port != 443) die("connection port changed\n");
        if (outbound.tls && outbound.tls.server_name && outbound.tls.server_name != "tls.example.com")
            die("TLS SNI was rewritten\n");
        if (source == config) push(exported, links.serialize_outbound_link(outbound));
    }
    if (length(keys(hosts)) != 9) die("expected all nine connection addresses\n");
    for (let i = 0; i < 9; i++)
        if (!hosts["_edge_" + i + ".eu_two_.example.com"]) die("connection address was changed\n");
}
fs.writefile(ARGV[2], join("\n", exported) + "\n");
' "$WORK_DIR/parsed.json" "$WORK_DIR/config.json" "$WORK_DIR/exported.txt"

ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/subscription/parser.uc" normalize-uri-list \
  "$WORK_DIR/exported.txt" "$WORK_DIR/reimported.json"
python3 - "$WORK_DIR/parsed.json" "$WORK_DIR/reimported.json" <<'PYCHECK'
import json
import sys
def addresses(path):
    return sorted((item["server"], item["server_port"], item["type"]) for item in json.load(open(path))["outbounds"])
assert addresses(sys.argv[1]) == addresses(sys.argv[2]), "export/import changed connection addresses"
PYCHECK
printf 'connection host parsing, generation and export/import checks passed\n'
