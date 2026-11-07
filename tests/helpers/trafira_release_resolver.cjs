// Exercise the production resolver, not the installer test's resolver stub.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'trafira/files/usr/lib/components/action.uc'), 'utf8');
const updater = path.join(root, 'trafira/files/usr/lib/components/updater.uc');
const start = source.indexOf('function resolve_trafira_release(');
const end = source.indexOf('\nfunction ', start + 1);
assert(start >= 0 && end > start);
const native = process.argv.includes('--native-helper');
let checked = 0;
for (const extension of ['apk', 'ipk']) {
  for (const translated of [false, true]) {
    for (const includeTranslation of [false, true]) {
      const names = [`trafira_3.0.1.${extension}`, `luci-app-trafira_3.0.1.${extension}`];
      if (includeTranslation) names.push(`luci-i18n-trafira-ru_3.0.1.${extension}`);
      const release = { tag_name: '3.0.1', html_url: 'https://example.invalid/release',
        assets: names.map(name => ({ name, browser_download_url: `https://example.invalid/${name}` })) };
      const context = {
        latest_trafira_release_json: () => JSON.stringify(release),
        is_apk: () => extension === 'apk', pkg_is_installed: () => translated,
        as_string: value => value == null ? '' : String(value),
        trim: value => value.trim(), split: (value, separator) => value.split(separator),
        replace: (value, pattern, replacement) => value.replace(pattern, replacement),
        length: value => value.length,
        helper_output_input: (input, mode, args) => {
          if (native) {
            // Node's socket-backed stdin cannot be reopened as /dev/stdin by
            // ucode fs.open on Linux. Supply a real descriptor instead.
            const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'trafira-release-plan-'));
            const file = path.join(dir, 'release.json');
            fs.writeFileSync(file, input);
            const descriptor = fs.openSync(file, 'r');
            try {
              const result = spawnSync('ucode', [updater, mode, ...args], {
                stdio: [descriptor, 'pipe', 'pipe'], encoding: 'utf8',
              });
              if (result.error) throw result.error;
              return result.status === 0 ? result.stdout : '';
            } finally {
              fs.closeSync(descriptor);
              fs.rmSync(dir, { recursive: true });
            }
          }
          // Local Windows check only: native CI always executes the real helper.
          if (translated && !includeTranslation) return '';
          return [release.html_url, names[0], release.assets[0].browser_download_url,
            names[1], release.assets[1].browser_download_url,
            translated ? names[2] : '', translated ? release.assets[2].browser_download_url : ''].join('\t') + '\n';
        },
      };
      vm.createContext(context);
      vm.runInContext(source.slice(start, end), context);
      const result = context.resolve_trafira_release('3.0.1');
      const label = `${extension}, installed translation=${translated}, translation asset=${includeTranslation}`;
      if (translated && !includeTranslation) assert.equal(result, null, label);
      else {
        assert(result, `valid release rejected: ${label}`);
        assert.equal(result.backend_name, names[0], label);
        assert.equal(result.app_name, names[1], label);
        assert.equal(result.i18n_name, translated ? names[2] : '', label);
        assert.equal(result.i18n_url, translated ? release.assets[2].browser_download_url : '', label);
      }
      checked++;
    }
  }
}
console.log(`${checked} production resolver cases passed; ${native ? 'real ucode release-plan helper' : 'modeled helper output (local Windows check)'}`);
