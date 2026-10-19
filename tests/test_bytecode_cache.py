"""Real ucode cache tests in disposable /tmp fixtures; never touch router files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
LIB = REPO / 'trafira/files/usr/lib'
UCODE = shutil.which('ucode')


@unittest.skipUnless(UCODE, 'ucode required')
class BytecodeCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='trafira-bytecode-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / '.trafira-bytecode-cache-test').touch()
        (self.root / 'meminfo').write_text('MemAvailable: 64000 kB\n')
        self.lib = self.root / 'lib'
        (self.lib / 'diagnostics').mkdir(parents=True)
        self.source = self.lib / 'diagnostics/runtime.uc'
        self.source.write_text('print("original:", ARGV[0] || "", "\\n");\n')
        self.runner = self.root / 'runner.uc'
        self.runner.write_text('let c=require("core.bytecode"); let s=c.run(getenv("FIXTURE_LIB"), getenv("FIXTURE_MODULE") || "diagnostics/runtime.uc", ARGV); if(s==null) { print("fallback\\n"); exit(77); } exit(s);\n')
        self.env = dict(os.environ, FIXTURE_LIB=str(self.lib), TRAFIRA_BYTECODE_TEST_ROOT=str(self.root))
        self.cache = self.root / 'cache'

    def command(self, *args, binary=None):
        return [binary or UCODE, '-L', str(LIB), str(self.runner), *args]

    def run_cache(self, *args, env=None, binary=None):
        return subprocess.run(self.command(*args, binary=binary), env=dict(self.env, **(env or {})), capture_output=True, text=True, timeout=15)

    def assert_ok(self, result, text='original:hello\n'):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, text)

    def compiled(self):
        return list(self.cache.glob('*.ucb'))

    def test_cold_and_warm_preserve_output_and_reuse_file(self):
        self.assert_ok(self.run_cache('hello'))
        files = self.compiled()
        self.assertEqual(len(files), 1)
        before = files[0].stat().st_mtime_ns
        self.assertTrue(files[0].read_bytes().startswith(b'\x1bucb'))
        self.assert_ok(self.run_cache('hello'))
        self.assertEqual(files[0].stat().st_mtime_ns, before)
        self.assertLessEqual(sum(p.stat().st_size for p in self.cache.rglob('*') if p.is_file()), 512 * 1024)
        self.assertEqual(self.source.read_text(), 'print("original:", ARGV[0] || "", "\\n");\n')

    def test_same_size_same_mtime_source_edit_invalidates_cache(self):
        self.assert_ok(self.run_cache('hello'))
        original = self.source.stat()
        self.source.write_text(self.source.read_text().replace('original', 'modified'))
        os.utime(self.source, ns=(original.st_atime_ns, original.st_mtime_ns))
        self.assert_ok(self.run_cache('hello'), 'modified:hello\n')

    def test_runtime_executable_change_invalidates_cache(self):
        self.assert_ok(self.run_cache('hello'))
        metadata = next(self.cache.glob('*.json')).read_text()
        binary = self.root / 'different-ucode'
        shutil.copy2(UCODE, binary)
        binary.chmod(0o755)
        self.assert_ok(self.run_cache('hello', binary=str(binary)))
        self.assertNotEqual(next(self.cache.glob('*.json')).read_text(), metadata)

    def test_corrupted_bytecode_is_not_executed(self):
        self.assert_ok(self.run_cache('hello'))
        self.compiled()[0].write_bytes(b'corrupt')
        self.assert_ok(self.run_cache('hello'))
        self.assertTrue(self.compiled()[0].read_bytes().startswith(b'\x1bucb'))

    def test_application_error_is_not_retried(self):
        marker = self.root / 'calls'
        self.source.write_text('let fs=require("fs"); let f=fs.open(getenv("CALLS"),"a"); f.write("called\\n"); f.close(); exit(7);\n')
        result = self.run_cache(env={'CALLS': str(marker)})
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(marker.read_text(), 'called\n')

    def test_compile_failure_returns_source_fallback(self):
        self.source.write_text('this is not valid ucode {')
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())
        self.assertFalse((self.cache / 'lock').exists())

    def test_low_memory_returns_fallback_without_cache_write(self):
        (self.root / 'meminfo').write_text('MemAvailable: 1000 kB\n')
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())

    def test_disabled_cache_returns_fallback(self):
        result = self.run_cache(env={'TRAFIRA_BYTECODE_CACHE': '0'})
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.cache.exists())

    def test_non_allowlisted_path_never_compiles(self):
        for name in ['../outside.uc', 'dns/apply.uc', '/etc/config/trafira']:
            result = self.run_cache(env={'FIXTURE_MODULE': name})
            self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())

    def test_cache_root_symlink_is_rejected(self):
        outside = self.root / 'outside'
        outside.mkdir()
        self.cache.symlink_to(outside, target_is_directory=True)
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_insecure_permissions_are_rejected(self):
        self.cache.mkdir(mode=0o777)
        self.cache.chmod(0o777)
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())

    def test_limit_exhaustion_returns_fallback(self):
        result = self.run_cache(env={'TRAFIRA_BYTECODE_TEST_LIMIT': '1'})
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())

    def test_large_source_returns_fallback(self):
        self.source.write_text('//'+('a' * (128 * 1024)))
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.compiled())

    def test_parallel_request_falls_back_without_waiting(self):
        self.source.write_text('let fs=require("fs"); fs.writefile(getenv("READY"),"ready"); system("sleep 2"); print("done\\n");\n')
        ready = self.root / 'ready'
        proc = subprocess.Popen(self.command(), env=dict(self.env, READY=str(ready)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(ready.exists())
        start = time.monotonic()
        result = self.run_cache()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertLess(time.monotonic() - start, 1)
        stdout, stderr = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, stderr)
        self.assertEqual(stdout, 'done\n')

    def test_stale_lock_recovers(self):
        self.cache.mkdir(mode=0o700)
        lock = self.cache / 'lock'
        lock.mkdir(mode=0o700)
        (lock / 'owner.json').write_text(json.dumps({'pid': '2147483647', 'start': '0'}))
        os.utime(lock, (1, 1))
        self.assert_ok(self.run_cache('hello'))

    def test_real_dispatchers_use_cache_without_changing_arguments(self):
        (self.lib / 'core').mkdir()
        shutil.copy2(LIB / 'core/bytecode.uc', self.lib / 'core/bytecode.uc')
        env = dict(self.env, TRAFIRA_LIB=str(self.lib))
        result = subprocess.run([UCODE, str(REPO / 'trafira/files/usr/bin/trafira'), 'show_version'], env=env, capture_output=True, text=True, timeout=10)
        self.assert_ok(result, 'original:show-version\n')
        self.assertEqual(len(self.compiled()), 1)
        (self.lib / 'config').mkdir()
        (self.lib / 'config/profile_cli.uc').write_text('print(ARGV[1], "\\n");\n')
        request = json.dumps({'action': 'list', 'name': "a'b; echo injected"})
        result = subprocess.run([UCODE, str(REPO / 'trafira/files/usr/bin/trafira-config'), 'profile_action', request], env=env, capture_output=True, text=True, timeout=10)
        self.assert_ok(result, request + '\n')
        self.assertEqual(len(self.compiled()), 2)

    def test_production_gate_does_not_use_non_tmpfs(self):
        result = self.run_cache(env={'TRAFIRA_BYTECODE_TEST_ROOT': str(self.root / 'missing')})
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertFalse(self.cache.exists())


if __name__ == '__main__':
    if not UCODE:
        raise SystemExit('ucode is required for cache integration tests')
    unittest.main()
