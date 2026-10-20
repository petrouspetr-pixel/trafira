"""Exercise ucode declaration order and component error extraction without services."""
from pathlib import Path
import json
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declarations(source, names):
    starts = list(re.finditer(r'^function (\w+)\(', source, re.M))
    result = []
    for i, item in enumerate(starts):
        if item[1] in names:
            end = starts[i + 1].start() if i + 1 < len(starts) else source.index('\nlet mode =', item.start())
            result.append(source[item.start():end])
    return '\n'.join(result)


def run_ucode(source):
    return subprocess.run(['ucode', '-'], input=source.encode(), capture_output=True, timeout=15)


def storage_fixture(available, variant, owned=False):
    source = (ROOT / 'trafira/files/usr/lib/components/action.uc').read_text(encoding='utf-8')
    setup = '''
let LIB_DIR="/fixture", github_error=null, selected_core=null, selected_request=null;
let selected_result={}, selected_error="", trafira_stopped_for_sing_box_change=false;
let retain_rollback_files=false;
let fs={lstat:()=>({type:"file"})};
function pkg_is_installed(name){return OWNED;}
function file_exists(path) {return true;}
function filesystem_available_bytes(path) {return AVAILABLE;}
function module_output(args) {return VARIANT;}
function updates_log(message,level) {}
function restart_trafira_after_failed_sing_box_change() {}
function cleanup_action() {print("CLEANUP\\n");}
function updates_response(success,component,action,message,current,latest,changed,status,url) {
    print(sprintf("%J\\n",{success,component,action,message}));
}
'''.replace('AVAILABLE', str(available)).replace('VARIANT', json.dumps(variant)).replace('OWNED', 'true' if owned else 'false')
    return setup + declarations(source, {
        'as_string', 'install_storage_required_bytes', 'install_storage_error',
        'ensure_install_storage', 'sing_box_runtime_output', 'action_fail', 'ram_extended_update_eligible',
    }) + '\nensure_install_storage("sing_box","install",0); print("PROCEED\\n");\n'


class ComponentPreflightTests(unittest.TestCase):
    def test_guard_is_declared_before_all_install_and_rollback_callers(self):
        source = (ROOT / 'trafira/files/usr/lib/components/action.uc').read_text(encoding='utf-8')
        declaration = source.index('function ensure_install_storage(')
        calls = list(re.finditer(r'(?<!function )\bensure_install_storage\(', source))
        self.assertTrue(calls)
        self.assertTrue(all(declaration < call.start() for call in calls))

    def test_extended_free_space_failure_is_structured_and_cleans_up(self):
        result = run_ucode(storage_fixture(21 * 1048576, 'extended'))
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertNotIn(b'Type error', result.stderr)
        payload = json.loads(result.stdout.splitlines()[0])
        self.assertFalse(payload['success'])
        self.assertIn('21 MiB available', payload['message'])
        self.assertIn('32 MiB required', payload['message'])
        self.assertIn(b'CLEANUP', result.stdout)
        self.assertNotIn(b'PROCEED', result.stdout)

    def test_extended_and_tiny_preflight_can_continue_with_required_space(self):
        for available, variant in [(40 * 1048576, 'extended'), (12 * 1048576, 'tiny')]:
            with self.subTest(variant=variant):
                result = run_ucode(storage_fixture(available, variant))
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(result.stdout, b'PROCEED\n')

    def test_package_owned_extended_can_use_ram_with_limited_flash(self):
        result = run_ucode(storage_fixture(int(13.13 * 1048576), 'extended', owned=True))
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b'PROCEED\n')
        result = run_ucode(storage_fixture(7 * 1048576, 'extended', owned=True))
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b'8 MiB required', result.stdout)

    def test_component_failure_keeps_error_not_ucode_pointer(self):
        source = (ROOT / 'trafira/files/usr/lib/components/updates.uc').read_text(encoding='utf-8')
        self.assertIn('function file_error_message_value(', source)
        logs = [
            ('Type error: left-hand side is not a function\nIn fn(), file /fixture, line 1:\n `source()`\n  Near here --------^\n', 'Type error: left-hand side is not a function'),
            ('progress\nERROR: package download failed\n', 'ERROR: package download failed'),
            ('', 'Failed to execute'),
        ]
        functions = declarations(source, {'as_string', 'text_first_chars', 'file_last_nonblank_line_value', 'file_error_message_value'})
        for log, expected in logs:
            with self.subTest(expected=expected):
                fixture = 'let fs={readfile:function(path){return ' + json.dumps(log) + ';}};\n'
                fixture += functions + '\nprint(file_error_message_value("fixture","Failed to execute",240));\n'
                result = run_ucode(fixture)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(result.stdout.decode(), expected)


if __name__ == '__main__':
    unittest.main()
