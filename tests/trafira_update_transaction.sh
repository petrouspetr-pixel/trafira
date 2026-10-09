#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('function install_trafira()');
const end = source.indexOf('\nfunction ', start + 1);
assert(start >= 0 && end > start);
// APK counts broken_scripts on unchanged installed packages in its result,
// including a backend whose previous pre-upgrade failed. Updating that backend
// clears the error; installing only the UI cannot repair it.
for (const apk of [true, false]) {
  for (const translated of [true, false]) {
    for (const failure of ['', 'download', 'install']) {
      const calls = [], downloads = [];
      let restarted = false, success = false, brokenBackend = apk;
      const context = {
        TRAFIRA_VERSION: '3.0.0', tmp_dir: '/tmp/update',
        latest_trafira_version: () => '3.0.1',
        write_trafira_latest_version_cache() {}, now_seconds: () => 1,
        init_tmp_dir: () => true, updates_log() {}, is_apk: () => apk,
        push: (a, x) => a.push(x),
        resolve_trafira_release: () => ({
          backend_name: 'backend', backend_url: 'backend-url',
          app_name: 'app', app_url: 'app-url',
          i18n_name: 'ru', i18n_url: translated ? 'ru-url' : '', release_url: 'release'
        }),
        download_with_retry: (_url, file) => { downloads.push(file); return failure !== 'download'; },
        pkg_install_files_command: files => Array.from(files),
        run_logged_install: (_label, files) => {
          calls.push(files);
          assert.strictEqual(downloads.length, translated ? 3 : 2, 'stage everything before installation');
          if (failure === 'install') return false;
          if (files.includes('/tmp/update/backend')) brokenBackend = false;
          return !brokenBackend;
        },
        package_failure_message: x => x,
        action_fail: (_c, _a, message) => { throw Error(message); },
        remove_file() {}, command_success() {}, file_exists: () => false,
        command_success_from_args() {},
        restart_trafira_after_successful_change: () => { restarted = true; },
        clear_version_caches() {}, installed_package_version: () => '3.0.1',
        action_success: (_c, _a, _m, version) => { assert.strictEqual(version, '3.0.1'); success = true; }
      };
      vm.createContext(context);
      vm.runInContext(source.slice(start, end), context);
      if (failure) {
        assert.throws(() => context.install_trafira(), /Failed to (download|install)/);
        assert(!success && !restarted, 'failed update must not report success or restart');
        assert.strictEqual(calls.length, failure === 'download' ? 0 : 1);
      } else {
        context.install_trafira();
        assert(success && restarted);
        const expected = ['/tmp/update/app', ...(translated ? ['/tmp/update/ru'] : []), '/tmp/update/backend'];
        if (apk) {
          assert.strictEqual(calls.length, 1, 'APK must update the entire release in one transaction');
          assert.deepStrictEqual(calls[0].slice().sort(), expected.slice().sort());
        } else {
          assert.deepStrictEqual(calls, expected.map(file => [file]), 'preserve opkg installation order');
        }
      }
    }
  }
}
console.log('Trafira update transaction tests passed');
NODE
