#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_SELECTOR_STATE_FILE="$WORK_DIR/state/selector-state.json"
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
fs.writefile(path, '{broken');
check(length(keys(state.read())) == 0, 'malformed state should be ignored');
check(choose('main', 'two', true).success, 'selection should recover malformed state');
fs.unlink(path); fs.mkdir(path, 448);
check(!choose('main', 'two', true).success, 'storage failure must not report success');
UCODE
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc"
printf 'persistent selector state checks passed\n'
