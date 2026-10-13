#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const root = process.argv[2];
const packaged = fs.readFileSync(`${root}/trafira/files/etc/config/trafira`, 'utf8').split('#config section')[0];
const defaults = Object.fromEntries([...packaged.matchAll(/^\s*option (\S+) '([^']*)'/gm)].map(m => [m[1],m[2]]));
const settingsSource = fs.readFileSync(`${root}/luci-app-trafira/htdocs/luci-static/resources/view/trafira/settings.js`, 'utf8');
const keys = ['exclude_ntp', 'exclude_wifi_calling', 'component_update_check_enabled'];
for (const key of keys) assert.equal(defaults[key], '1', `fresh install: ${key}`);
function options(values) {
  const found = {};
  const context = {
    form: {}, widgets: {}, _: s => s,
    L: {toArray: v => v == null ? [] : [].concat(v)},
    uci: {get: (_pkg, _section, key) => values[key]},
    main: {TRAFIRA_UCI_PACKAGE:'trafira', DNS_SERVER_OPTIONS:{}, BOOTSTRAP_DNS_SERVER_OPTIONS:{}, getClashUIUrl: () => 'http://localhost:9090'},
    baseclass: {extend: x => x}
  };
  const api = vm.runInNewContext(`(function(){${settingsSource}})()`, context);
  api.createSettingsContent({option(_type, key) {
    return found[key] = {option:key, value(){}, depends(){}, cfgvalue(){return values[key]}, map:{}};
  }}, {});
  return found;
}
for (const values of [defaults, Object.fromEntries(keys.map(k=>[k,'0'])), Object.fromEntries(keys.map(k=>[k,'1'])), {}]) {
  const fields = options(values);
  for (const key of keys) {
    assert.equal(fields[key].default, '1', `LuCI declared default: ${key}`);
    // LuCI uses the declared default only when cfgvalue returns null/undefined.
    const configured = fields[key].cfgvalue('settings');
    assert.equal(configured ?? fields[key].default, values[key] ?? '0', `preserve existing/missing: ${key}`);
  }
}
console.log('Fresh defaults and existing LuCI settings preservation passed');
NODE
