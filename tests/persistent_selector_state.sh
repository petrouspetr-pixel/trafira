#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAIL: persistent selector state at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_SELECTOR_STATE_FILE="$WORK_DIR/state/selector-state.json"
assert_saved() {
  node - "$TRAFIRA_SELECTOR_STATE_FILE" "$1" "$2" <<'JS'
const fs=require('fs'),assert=require('assert/strict');
const state=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
assert.equal(state[process.argv[3]],process.argv[4],`saved selection for ${process.argv[3]}`);
JS
}
assert_result() {
  node - "$WORK_DIR/result" "$1" "$2" <<'JS'
const fs=require('fs'),assert=require('assert/strict');
const result=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
assert.equal(result.success,process.argv[3]==='true','API success result');
if(process.argv[4])assert.equal(result.error,process.argv[4],'API error result');
JS
}
cat >"$WORK_DIR/check.uc" <<'UCODE'
let fs = require('fs');
let state = require('singbox.selector_state');
let path = getenv('TRAFIRA_SELECTOR_STATE_FILE');
function check(ok, message) { if (!ok) { warn(message, '\n'); exit(1); } }
let proxies = { proxies: {
    main: { type: 'Selector', now: 'one', all: [ 'one', 'two' ] },
    other: { type: 'Selector', now: 'alpha', all: [ 'alpha', 'beta' ] },
    auto: { type: 'URLTest', now: 'one', all: [ 'one', 'two' ] }
} };
function choose(group, node, success) {
    return state.choose(group, node, function() { return proxies; },
        function() { return { success }; });
}
check(choose('main', 'two', true).success, 'explicit selection should persist');
check((fs.stat(path).mode & 511) == 384, 'state must be private');
let inode = fs.stat(path).inode;
check(inode != null, 'filesystem must expose inode for flash-write regression');
check(choose('main', 'two', true).success, 'repeated selection should succeed');
check(fs.stat(path).inode == inode, 'unchanged choice must not rewrite flash');
check(!choose('other', 'beta', false).success, 'failed API must fail');
check(state.read().other == null, 'failed API must not persist');
check(!choose('main', 'removed', true).success, 'missing node must fail');
check(!choose('auto', 'two', true).success, 'URLTest must not persist');
let config = { outbounds: [ { type: 'selector', tag: 'main', outbounds: [ 'one', 'two' ], default: 'one' } ] };
state.apply(config);
check(config.outbounds[0].default == 'two', 'reboot generation must restore choice');
config.outbounds[0].outbounds = [ 'one' ]; config.outbounds[0].default = 'one';
state.apply(config);
check(config.outbounds[0].default == 'one', 'deleted selection must retain generated fallback');
check(choose('other', 'beta', true).success, 'second group should persist');
check(state.read().main == 'two' && state.read().other == 'beta', 'writes must preserve other groups');
let disabled = proxies.proxies.main;
delete proxies.proxies.main;
check(choose('other', 'alpha', true).success, 'other group should change while main is disabled');
check(state.read().main == 'two', 'temporarily disabled group must keep its saved choice');
proxies.proxies.main = disabled;
config.outbounds[0].outbounds = [ 'one', 'two' ]; config.outbounds[0].default = 'one';
state.apply(config);
check(config.outbounds[0].default == 'two', 'reenabled group must recover its saved choice');
fs.writefile(path, '{broken');
check(length(keys(state.read())) == 0, 'malformed state should be ignored');
check(choose('main', 'two', true).success, 'selection should recover malformed state');
fs.unlink(path); fs.mkdir(path, 448);
check(!choose('main', 'two', true).success, 'storage failure must not report success');
UCODE
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc"
printf 'persistent selector module checks passed\n'
rm -rf "$TRAFIRA_SELECTOR_STATE_FILE"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
case "$*" in
  *'-X PUT'*) printf '\n%s' "$FAKE_HTTP_STATUS"; exit "${FAKE_CURL_EXIT:-0}" ;;
  *) printf '%s' '{"proxies":{"main":{"type":"Selector","now":"one","all":["one","two"]},"other":{"type":"Selector","now":"alpha","all":["alpha","beta"]}}}' ;;
esac
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH" TRAFIRA_LIB
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci-state"
printf '%s\n' 'trafira.settings=settings' >"$TRAFIRA_UCI_STATE_FILE"
runtime="$TRAFIRA_LIB/diagnostics/runtime.uc"
if FAKE_HTTP_STATUS=404 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy main two >"$WORK_DIR/result"; then
  echo 'HTTP failure reported success' >&2; exit 1
fi
assert_result false group_not_found
test ! -f "$TRAFIRA_SELECTOR_STATE_FILE"
if FAKE_HTTP_STATUS=204 FAKE_CURL_EXIT=7 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy main two >"$WORK_DIR/result"; then
  echo 'curl failure reported success' >&2; exit 1
fi
assert_result false selector_api_failed
test ! -f "$TRAFIRA_SELECTOR_STATE_FILE"
FAKE_HTTP_STATUS=204 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy main two >"$WORK_DIR/result"
assert_result true ''
assert_saved main two
FAKE_HTTP_STATUS=204 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy main one transient >"$WORK_DIR/result"
assert_result true ''
assert_saved main two
# Independent processes must merge their selections under the same stable lock.
FAKE_HTTP_STATUS=204 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy main two >"$WORK_DIR/a" &
first=$!
FAKE_HTTP_STATUS=204 ucode -L "$TRAFIRA_LIB" "$runtime" clash-api set_group_proxy other beta >"$WORK_DIR/b" &
second=$!
wait "$first"; wait "$second"
assert_saved main two
assert_saved other beta
printf 'persistent selector HTTP and concurrency checks passed\n'
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"main",".type":"section","action":"connection","enabled":"1","selector_proxy_links":["socks5://127.0.0.1:1080#First","socks5://127.0.0.1:1081#Second"]}]}
JSON
mkdir -p "$WORK_DIR/config.json.section-cache"
generate() {
  ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1 0 1 '' 1.14.1
}
generate
node - "$WORK_DIR/config.json" "$TRAFIRA_SELECTOR_STATE_FILE" <<'JS'
const fs=require('fs'),assert=require('assert/strict');
const group=JSON.parse(fs.readFileSync(process.argv[2])).outbounds.find(o=>o.type==='selector' && o.tag==='main-out');
assert(group && group.outbounds.length>=2);
fs.writeFileSync(process.argv[3],JSON.stringify({[group.tag]:group.outbounds[1]}));
JS
generate
node - "$WORK_DIR/config.json" "$TRAFIRA_SELECTOR_STATE_FILE" "$WORK_DIR/fixture.json" <<'JS'
const fs=require('fs'),assert=require('assert/strict');
const group=JSON.parse(fs.readFileSync(process.argv[2])).outbounds.find(o=>o.tag==='main-out');
assert.equal(group.default,JSON.parse(fs.readFileSync(process.argv[3]))['main-out'],'generator must restore explicit choice after reboot');
const fixture=JSON.parse(fs.readFileSync(process.argv[4]));
fixture.section[0].selector_proxy_links.pop();fs.writeFileSync(process.argv[4],JSON.stringify(fixture));
JS
generate
node - "$WORK_DIR/config.json" <<'JS'
const fs=require('fs'),assert=require('assert/strict');
const group=JSON.parse(fs.readFileSync(process.argv[2])).outbounds.find(o=>o.tag==='main-out');
assert.equal(group.default,group.outbounds[0],'removed choice must use generated fallback');
JS
printf 'persistent selector state checks passed\n'
