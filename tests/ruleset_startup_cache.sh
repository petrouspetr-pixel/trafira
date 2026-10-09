#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
# A rejected download must never replace the last validated copy.
grep -q 'valid-rules' "$3" || exit 1
cp "$3" "$5"
SH
chmod +x "$WORK_DIR/bin/sing-box"
cat >"$WORK_DIR/test.uc" <<'UC'
let fs = require("fs");
let cache = require("singbox.ruleset_cache");
function check(value, message) { if (!value) die(message + "\n"); }
let rule = { type: "remote", tag: "test", url: "https://example.org/rules.srs", format: "binary", http_client: { detour: "proxy-out" } };
let file = ARGV[0] + "/download";
let config = {route: {rule_set: [rule]}};
cache.apply(config, "1.14.2");
check(!rule.initial_path, "cold first run must not get a nonexistent cache");
fs.writefile(file, "valid-rules-v1");
check(cache.save(rule, file), "save validated copy");
cache.apply(config, "1.14.2");
check(fs.readfile(rule.initial_path) == "valid-rules-v1", "offline startup uses persistent copy");
check(rule.type == "remote" && rule.http_client.detour == "proxy-out", "keep updates and selected proxy");
let saved = rule.initial_path;
fs.writefile(file, "invalid HTML error");
check(!cache.save(rule, file), "reject bad replacement");
check(fs.readfile(saved) == "valid-rules-v1", "preserve valid copy after failed validation");
fs.writefile(file, "valid-rules-v2");
check(cache.save(rule, file), "publish valid update");
check(fs.readfile(saved) == "valid-rules-v2", "replace atomically");
let changed = {type: "remote", tag: "test", url: "https://other.example/rules.srs", format: "binary"};
cache.apply({route: {rule_set: [changed]}}, "1.14.2");
check(!changed.initial_path, "changed URL cannot reuse old list");
let legacy = {type: "remote", tag: "test", url: rule.url, format: "binary"};
cache.apply({route: {rule_set: [legacy]}}, "1.13.21");
check(!legacy.initial_path, "legacy core must not receive unsupported field");
fs.writefile(saved, "corrupt");
delete rule.initial_path;
cache.apply(config, "1.14.2");
check(!rule.initial_path, "corrupt cache cannot poison startup");
print("Rule-set startup cache checks passed\n");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/test.uc" "$WORK_DIR"
