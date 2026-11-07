const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '../../trafira/files/usr/lib/components/action.uc'), 'utf8');
function body(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, name);
  const end = source.indexOf('\nfunction ', start + 1);
  // ucode iterates array values with "in"; JavaScript uses "of".
  return source.slice(start, end).replaceAll('for (let item in ', 'for (let item of ');
}
const library = '/usr/lib/libcronet.so';
const functions = [
  'move_file_portable', 'move_file_to_backup', 'restore_file_backup',
  'restore_sing_box_after_failed_extended_install',
  'restore_sing_box_after_failed_extended_package_install',
  'install_sing_box_extended', 'install_sing_box_extended_package'
];
function fixture(oldLibrary, failBackup, failRestore = false) {
  const files = new Map([['/usr/bin/sing-box', 'old-core']]);
  if (oldLibrary) files.set(library, 'old-library');
  const exists = p => files.has(p) || p.startsWith('/tmp/mock/');
  const context = {
    as_string: x => x == null ? '' : String(x), tmp_dir: '/tmp/mock', selected_core: null,
    ram_extended_update: false, isolated_extended_apk_update: false, retain_rollback_files: false,
    owner_pid: () => 123, file_exists: p => files.has(p), file_nonempty: exists,
    fs: { lstat: p => files.has(p) ? { type: 'file' } : null, rename: (from, to) => {
      if (!files.has(from) || (from === library && failBackup) ||
        (to === library + '.trafira-backup.123' && failBackup === 'rename') || (to === library && failRestore)) return false;
      files.set(to, files.get(from)); files.delete(from); return true;
    } },
    remove_file: p => files.delete(p),
    command_success_from_args: args => {
      if (args[0] !== 'cp') return true;
      const from = args[2], to = args[3];
      if (!files.has(from) || (to.startsWith(library) && failRestore)) return false;
      if (from === library && failBackup === 'copy') { files.set(to, 'partial-copy'); return false; }
      files.set(to, files.get(from)); return true;
    },
    command_success: () => true, command_from_args: () => '', shell_quote: x => x,
    init_tmp_dir: () => true, ensure_tmp_download_capacity: () => true,
    sing_box_runtime_output: mode => mode === 'variant' ? 'extended-compressed' : 'old-extended',
    resolve_sing_box_extended_release: () => ({ tag: 'new', asset_name: 'core.tgz', asset_url: 'url' }),
    normalize_sing_box_version: x => x, download_with_retry: () => true,
    select_archive_member_path: (_file, name) => name, ensure_install_storage() {}, staged_install_bytes: () => 1,
    is_apk: () => false, stage_previous_sing_box_package: () => true,
    stop_trafira_before_sing_box_change() {}, validate_sing_box_extended_binary: () => 'new-extended',
    run_logged_pkg_remove_sing_box_conflict: () => true, remove_managed_sing_box_service_script() {},
    install_managed_sing_box_service_script: () => true,
    install_staged_file: (_from, to) => { files.set(to, 'new-library'); return to !== library; },
    restore_sing_box_install_backup: () => true, restore_sing_box_variant_state() {},
    restore_sing_box_service_from_marker: () => true, clear_version_caches() {},
    action_fail: (_component, _action, message) => { throw Error(message); },
    rollback_archive_field: () => 'new-version', installed_package_version: () => 'old-version',
    run_logged: () => true, pkg_list_update_command: () => '', ram_extended_update_eligible: () => false,
    prepare_sing_box_package_service_install() {}, pkg_remove_sing_box_conflict: () => true,
    run_logged_install: () => { files.set(library, 'new-library'); return false; },
    pkg_install_files_command: () => '', package_failure_message: x => x,
  };
  vm.createContext(context);
  vm.runInContext(functions.map(body).join('\n'), context);
  return { files, context };
}

for (const packaged of [false, true]) {
  for (const oldLibrary of [true, false]) {
    for (const failBackup of oldLibrary ? ['copy', 'rename', false] : [false]) {
      const { files, context } = fixture(oldLibrary, failBackup);
      const label = `${packaged ? 'package' : 'compressed'} old=${oldLibrary} backupFailure=${failBackup}`;
      assert.throws(() => packaged ? context.install_sing_box_extended_package('install_extended') :
        context.install_sing_box_extended('install_extended_compressed', true), /Failed to (backup|install)/, label);
      assert.equal(files.get(library), oldLibrary ? 'old-library' : undefined, `${label}: restore exact original state`);
      assert(![...files.values()].includes('partial-copy'), `${label}: remove partial backup staging`);
      console.log(`PASS ${label}`);
    }
  }
}

{
  // Fresh installation skips the early backup block and reaches its later guard.
  const { files, context } = fixture(true, 'copy');
  context.sing_box_runtime_output = mode => mode === 'variant' ? 'not-installed' : '';
  assert.throws(() => context.install_sing_box_extended_package('install_extended'), /Failed to backup current libcronet/);
  assert.equal(files.get(library), 'old-library', 'late package backup failure preserves unrelated existing library');
  console.log('PASS package late backup guard');
}

for (const rollback of ['restore_sing_box_after_failed_extended_install', 'restore_sing_box_after_failed_extended_package_install']) {
  const { files, context } = fixture(true, false, true);
  files.set('/old-library-backup', 'old-library');
  files.set(library, 'new-library');
  assert.equal(context[rollback]('extended-compressed', '', '/old-library-backup', '', '', '', true), false,
    `${rollback}: failed restore must report failure`);
  assert.equal(context.retain_rollback_files, true, `${rollback}: retain recovery material`);
  assert.equal(files.get('/old-library-backup'), 'old-library');
}
for (const rollback of ['restore_sing_box_after_failed_extended_install', 'restore_sing_box_after_failed_extended_package_install']) {
  const { files, context } = fixture(false, false);
  files.set(library, 'new-library');
  // remove_file() intentionally swallows unlink errors in production.
  context.remove_file = p => { if (p !== library) files.delete(p); };
  assert.equal(context.restore_file_backup(library, ''), false, 'failed removal of new library must report failure');
  assert.equal(context[rollback]('not-installed', '', '', '', '', '', true), false,
    `${rollback}: failed removal must report failure`);
  assert.equal(context.retain_rollback_files, true, `${rollback}: retain recovery material after unlink failure`);
  assert.equal(files.get(library), 'new-library', 'fault injection must leave the undeleted library');
  console.log(`PASS ${rollback} old absent unlink failure`);
}
{
  const { files, context } = fixture(true, false);
  assert.equal(context.restore_file_backup(library, '/missing-backup'), false, 'missing named backup is an error');
  assert.equal(files.get(library), 'old-library', 'missing named backup must preserve existing target');
}
console.log('libcronet backup and rollback regression checks passed');
