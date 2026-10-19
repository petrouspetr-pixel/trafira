"""Run the actual POSIX uninstaller against disposable package/service fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SHELL = shutil.which('sh') or ('C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else None)


def shell_path(path):
    value = str(path).replace('\\', '/')
    return '/' + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ':' else value


@unittest.skipUnless(SHELL, 'POSIX shell required')
class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='trafira-uninstall-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['etc/config', 'etc/trafira/profiles', 'usr/bin', 'usr/lib/trafira/service', 'etc/init.d', 'root', 'tmp', 'bin', 'state']:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / '.trafira-uninstall-test-root').touch()
        (self.root / 'etc/config/trafira').write_text('original settings\n')
        (self.root / 'etc/config/dhcp').write_text('custom DNS\n')
        (self.root / 'etc/trafira/profiles/home.json').write_text('private-profile\n')
        (self.root / 'etc/config/trafira.apk-new').write_text('default settings\n')
        self.installed = self.root / 'state/installed'
        self.installed.write_text('trafira\nluci-app-trafira\nluci-i18n-trafira-ru\nsing-box-extended\nzapret2\nother-service\n')
        self.log = self.root / 'state/log'
        self.log.touch()
        self.env = dict(os.environ, TRAFIRA_UNINSTALL_TEST_MODE='1', TRAFIRA_UNINSTALL_ROOT=shell_path(self.root),
                        STATE=shell_path(self.root / 'state'), PATH=shell_path(self.root / 'bin') + os.pathsep + os.environ['PATH'])
        self.write('usr/bin/trafira', '''#!/bin/sh
printf 'helper %s keep=%s\\n' "$*" "${TRAFIRA_UNINSTALL_KEEP_COMPONENTS:-0}" >>"$STATE/log"
[ "${FAIL_HELPER:-0}" != 1 ] || exit 9
if [ "${TRAFIRA_UNINSTALL_KEEP_COMPONENTS:-0}" != 1 ]; then
  rm -f "$TRAFIRA_UNINSTALL_ROOT/usr/bin/sing-box" "$TRAFIRA_UNINSTALL_ROOT/etc/init.d/sing-box"
fi
''')
        self.write('etc/init.d/trafira', '''#!/bin/sh
printf 'service %s\\n' "$*" >>"$STATE/log"
case "$1" in status|enabled) exit 1;; esac
''')
        (self.root / 'usr/lib/trafira/service/package.uc').write_text('TRAFIRA_UNINSTALL_KEEP_COMPONENTS')
        self.manager('apk')

    def write(self, name, content):
        path = self.root / name
        path.write_bytes(content.encode())
        path.chmod(0o755)

    def manager(self, kind):
        for name in ['apk', 'opkg']:
            (self.root / 'bin' / name).unlink(missing_ok=True)
        self.kind = kind
        self.env['TRAFIRA_UNINSTALL_PACKAGE_MANAGER'] = kind
        self.write('bin/' + kind, '''#!/bin/sh
case "$1" in
 info|list-installed)
   [ "${FAIL_LIST:-0}" != 1 ] || exit 4
   if [ "$1" = info ]; then cat "$STATE/installed"; else sed 's/$/ - 1.0/' "$STATE/installed"; fi
   exit 0;;
 del|remove)
   shift
   printf 'remove %s\\n' "$*" >>"$STATE/log"
   [ "${DAMAGE_CONFIG:-0}" != 1 ] || rm -f "$TRAFIRA_UNINSTALL_ROOT/etc/config/trafira"
   [ "${FAIL_REMOVE:-0}" != 1 ] || exit 7
   for name in "$@"; do
     [ "${REFUSE_PACKAGE:-}" != "$name" ] || continue
     sed "/^${name}\\$/d" "$STATE/installed" >"$STATE/next"
     mv "$STATE/next" "$STATE/installed"
   done
   exit 0;;
 *) exit 8;;
esac
''')

    def run_script(self, *args, input=None, env=None):
        result = subprocess.run([SHELL, str(REPO / 'uninstall.sh'), *args], input=input.encode() if input else None,
                                capture_output=True, env=dict(self.env, **(env or {})), timeout=20)
        result.stdout = result.stdout.decode('utf-8', errors='replace')
        result.stderr = result.stderr.decode('utf-8', errors='replace')
        return result

    def backups(self):
        return list((self.root / 'root').glob('trafira-uninstall-*/settings.tar.gz'))

    def test_defaults_preserve_settings_profiles_components_and_unrelated_services(self):
        for kind in ['apk', 'opkg']:
            with self.subTest(kind=kind):
                self.manager(kind)
                result = self.run_script('--yes')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.root / 'etc/config/trafira').read_text(), 'original settings\n')
                self.assertTrue((self.root / 'etc/trafira/profiles/home.json').exists())
                self.assertIn('sing-box-extended', self.installed.read_text())
                self.assertIn('other-service', self.installed.read_text())
                self.assertNotIn('luci-app-trafira', self.installed.read_text())
                self.assertTrue(self.backups())
                self.installed.write_text('trafira\nluci-app-trafira\nsing-box-extended\nzapret2\nother-service\n')

    def test_purge_keeps_external_backup_and_unrelated_dns(self):
        result = self.run_script('--yes', '--purge')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'etc/config/trafira').exists())
        self.assertFalse((self.root / 'etc/config/trafira.apk-new').exists())
        self.assertFalse((self.root / 'etc/trafira').exists())
        self.assertEqual((self.root / 'etc/config/dhcp').read_text(), 'custom DNS\n')
        self.assertTrue(self.backups())

    def test_remove_components_is_opt_in_and_allowlisted(self):
        result = self.run_script('--yes', '--remove-components')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed.read_text(), 'other-service\n')

    def test_dry_run_does_not_write_or_stop_anything(self):
        result = self.run_script('--dry-run', '--purge', '--remove-components')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text(), '')
        self.assertFalse(self.backups())
        self.assertTrue((self.root / 'etc/config/trafira').exists())

    def test_interactive_cancellation_does_nothing(self):
        result = self.run_script(input='\n\nno\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text(), '')
        self.assertFalse(self.backups())

    def test_interactive_defaults_and_confirmation(self):
        result = self.run_script(input='\n\ny\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('trafira\n', self.installed.read_text())
        self.assertTrue((self.root / 'etc/config/trafira').exists())

    def test_package_failure_restores_config_even_in_purge_mode(self):
        result = self.run_script('--yes', '--purge', env={'FAIL_REMOVE': '1', 'DAMAGE_CONFIG': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'etc/config/trafira').read_text(), 'original settings\n')
        self.assertTrue((self.root / 'etc/trafira/profiles/home.json').exists())
        self.assertTrue(self.backups())

    def test_dns_cleanup_failure_prevents_package_removal_and_purge(self):
        result = self.run_script('--yes', '--purge', env={'FAIL_HELPER': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith('remove ') for line in self.log.read_text().splitlines()))
        self.assertTrue((self.root / 'etc/config/trafira').exists())

    def test_package_manager_failure_is_not_treated_as_empty_installation(self):
        result = self.run_script('--yes', env={'FAIL_LIST': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')

    def test_refused_removal_stops_before_purge(self):
        result = self.run_script('--yes', '--purge', env={'REFUSE_PACKAGE': 'trafira'})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'etc/config/trafira').exists())

    def test_managed_sing_box_is_preserved_by_default(self):
        self.write('etc/init.d/sing-box', '# Trafira managed sing-box service for binary variants\n')
        self.write('usr/bin/sing-box', 'managed core\n')
        result = self.run_script('--yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'usr/bin/sing-box').exists())
        self.assertIn('keep=1', self.log.read_text())

    def test_legacy_managed_helper_cannot_silently_delete_kept_component(self):
        self.write('etc/init.d/sing-box', '# Trafira managed sing-box service for binary variants\n')
        (self.root / 'usr/lib/trafira/service/package.uc').write_text('legacy helper')
        result = self.run_script('--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')

    def test_unknown_option_and_untrusted_fixture_root_are_rejected(self):
        for args, env in [(('--oops',), {}), (('--yes',), {'TRAFIRA_UNINSTALL_TEST_MODE': '0'})]:
            result = self.run_script(*args, env=env)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')

    def test_repeated_run_handles_missing_packages(self):
        self.assertEqual(self.run_script('--yes').returncode, 0)
        result = self.run_script('--yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_backup_failure_prevents_any_removal(self):
        self.write('bin/tar', '#!/bin/sh\nexit 5\n')
        result = self.run_script('--yes', '--purge')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')
        self.assertTrue((self.root / 'etc/config/trafira').exists())


    def test_backup_contains_original_configuration_and_profiles(self):
        result = self.run_script('--yes', '--purge')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tarfile.open(self.backups()[0]) as archive:
            self.assertEqual(archive.extractfile('etc/config/trafira').read().decode().replace('\r\n', '\n'), 'original settings\n')
            self.assertEqual(archive.extractfile('etc/trafira/profiles/home.json').read().decode().strip(), 'private-profile')

    def test_keep_restores_configuration_removed_by_package_manager(self):
        result = self.run_script('--yes', env={'DAMAGE_CONFIG': '1'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'etc/config/trafira').read_text(), 'original settings\n')

    def test_component_dependency_refusal_does_not_purge_settings(self):
        result = self.run_script('--yes', '--purge', '--remove-components', env={'REFUSE_PACKAGE': 'zapret2'})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'etc/config/trafira').exists())
        self.assertTrue(self.backups())

    def test_archive_verification_failure_prevents_removal(self):
        self.write('bin/gzip', '#!/bin/sh\nexit 5\n')
        result = self.run_script('--yes', '--purge')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')
        self.assertTrue((self.root / 'etc/config/trafira').exists())

    def test_concurrent_uninstall_does_not_change_settings(self):
        (self.root / 'tmp/trafira-uninstall.lock').mkdir()
        result = self.run_script('--yes', '--purge')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), '')
        self.assertFalse(self.backups())

    def test_end_of_input_cancels_without_changes(self):
        result = self.run_script(input='\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text(), '')
        self.assertFalse(self.backups())


if __name__ == '__main__':
    unittest.main()
