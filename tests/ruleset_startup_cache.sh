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
cat >"$WORK_DIR/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [ -f "$TRAFIRA_RULESET_CACHE_DIR/../low-space" ]; then
    printf 'test 10000 9000 1000 90%% /\n'
else
    printf 'test 100000 1000 99000 1%% /\n'
fi
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TRAFIRA_RULESET_CACHE_DIR/../curl.log"
[ ! -f "$TRAFIRA_RULESET_CACHE_DIR/../offline" ] || exit 28
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf 'valid-rules-refreshed' >"$2"; exit 0; fi
    shift
done
exit 1
SH
chmod +x "$WORK_DIR/bin/df" "$WORK_DIR/bin/curl"
node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
for (const [name, size] of [['oversized', 4194305], ['quota-input', 3145728], ['filler', 6291456]]) {
  const data = Buffer.alloc(size, 32);
  data.write('valid-rules');
  fs.writeFileSync(`${dir}/${name}`, data);
}
NODE
cat >"$WORK_DIR/test.uc" <<'UC'
let fs = require("fs");
let cache = require("singbox.ruleset_cache");
let diagnostics = require("singbox.startup_diagnostics");
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
let mtime = fs.stat(saved).mtime;
system("sleep 1");
check(cache.save(rule, file) && fs.stat(saved).mtime == mtime, "unchanged copy must not write flash");
fs.writefile(ARGV[0] + "/low-space", "1");
fs.writefile(file, "valid-rules-new");
check(!cache.save(rule, file) && fs.readfile(saved) == "valid-rules-v2", "reserve space and preserve old copy");
fs.unlink(ARGV[0] + "/low-space");
check(!cache.save(rule, ARGV[0] + "/oversized"), "bound individual snapshot size");
fs.rename(ARGV[0] + "/filler", getenv("TRAFIRA_RULESET_CACHE_DIR") + "/filler");
check(!cache.save(rule, ARGV[0] + "/quota-input"), "bound total including staging space");
fs.unlink(getenv("TRAFIRA_RULESET_CACHE_DIR") + "/filler");
let source = {type: "remote", tag: "json", url: "https://example.org/rules.json", format: "source"};
check(cache.save(source, file), "source-format snapshot validated with compile");
cache.apply({route:{rule_set:[source]}}, "1.14.2");
check(source.initial_path && source.format == "source", "preserve source format");
check(cache.refresh(config, "127.0.0.1:4535"), "refresh through selected proxy");
let calls = fs.readfile(ARGV[0] + "/curl.log");
check(index(calls, "--proxy http://127.0.0.1:4535 --noproxy") >= 0, "downloads honor proxy");
check(index(calls, "--max-time 30 --max-filesize 4194304") >= 0, "download bounded in time and size");
fs.writefile(ARGV[0] + "/offline", "1");
fs.writefile(ARGV[0] + "/curl.log", "");
check(!cache.refresh(config, "127.0.0.1:4535"), "report refresh failure");
check(fs.readfile(saved) == "valid-rules-refreshed", "download failure preserves cache");
check(length(split(trim(fs.readfile(ARGV[0] + "/curl.log")), "\n")) == 1, "no silent direct fallback");
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
let marker = "test-start-marker";
let logs = "sing-box[1]: FATAL old error\ntrafira: " + marker + "\nsing-box[2]: FATAL initial rule-set: test: Get https://user:secret@example.org/private?token=secret: timeout\n";
let reason = diagnostics.reason(logs, marker);
check(index(reason, "initial rule-set") >= 0 && index(reason, "secret") < 0, "current failure with URLs redacted");
check(diagnostics.reason(logs, "missing-marker") == "", "never attribute stale errors");
print("Rule-set startup cache checks passed\n");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/test.uc" "$WORK_DIR"
