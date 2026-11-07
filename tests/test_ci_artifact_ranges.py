"""Offline range transport tests; fake curl runs as a real child on Windows/Linux."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FAKE_CURL = r'''
import json, os
from pathlib import Path
import sys, time

def option(name):
    for index, value in enumerate(sys.argv[1:], 1):
        if value == name:
            return sys.argv[index + 1]
        if value.startswith(name + '='):
            return value.split('=', 1)[1]
    raise RuntimeError('missing option ' + name)

start, end = map(int, option('--range').split('-'))
payload = Path(os.environ['FAKE_RANGE_PAYLOAD']).read_bytes()
mode = os.environ.get('FAKE_RANGE_MODE', 'valid')
events = Path(os.environ['FAKE_RANGE_EVENTS'])
record = {'pid': os.getpid(), 'start': start, 'end': end, 'at': time.time_ns()}
(events / (str(os.getpid()) + '-start.json')).write_text(json.dumps(record))
if mode == 'deadline':
    time.sleep(20)
time.sleep(0.08)
body = payload[start:end + 1]
status = '200' if mode == 'http200' else '206'
reported = f'bytes {start}-{end}/{len(payload)}'
if mode == 'wrongrange':
    reported = f'bytes {start + 1}-{end}/{len(payload)}'
elif mode == 'wrongtotal':
    reported = f'bytes {start}-{end}/{len(payload) + 1}'
elif mode == 'redirectbad':
    reported = f'bytes {start + 1}-{end}/{len(payload)}'
header = 'HTTP/2 ' + status + '\r\n'
if mode not in ('missingrange', 'redirectmissing'):
    header += 'Content-Range: ' + reported + '\r\n'
header += f'Content-Length: {end - start + 1}\r\n\r\n'
if mode in ('redirectgood', 'redirectbad', 'redirectmissing'):
    previous = f'bytes {start}-{end}/{len(payload)}' if mode in ('redirectbad', 'redirectmissing') else 'bytes 0-0/1'
    header = 'HTTP/1.1 302 Found\r\nContent-Range: ' + previous + '\r\nLocation: https://cdn.fixture/file\r\n\r\n' + header
if mode == 'shortbody':
    body = body[:-1]
elif mode == 'corrupt':
    body = bytes([body[0] ^ 1]) + body[1:]
elif mode == 'curlerror':
    body = body[:3]
Path(option('--output')).write_bytes(body)
Path(option('--dump-header')).write_bytes(header.encode())
record['at'] = time.time_ns()
(events / (str(os.getpid()) + '-end.json')).write_text(json.dumps(record))
sys.stdout.write(status)
sys.exit(7 if mode == 'curlerror' else 0)
'''


def process_alive(pid):
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            code = ctypes.c_uint32()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class VerifiedRangeDownloads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ci_verified_range', ROOT / 'tools/download-verified-range.py')
        cls.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.module
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='trafira-ci-ranges-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.output = self.work / 'output'
        self.output.mkdir()
        self.destination = self.output / 'sdk.tar.zst'
        self.previous = b'prior verified SDK must survive every failure'
        self.destination.write_bytes(self.previous)
        self.payload = bytes(range(256)) * 4 + b'final partial chunk'
        self.source = self.work / 'payload.bin'
        self.source.write_bytes(self.payload)
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.events = self.work / 'events'
        self.events.mkdir()
        self.fake = self.work / 'fakecurl.py'
        self.fake.write_text(FAKE_CURL)
        self.environment = patch.dict(os.environ, FAKE_RANGE_PAYLOAD=str(self.source),
                                      FAKE_RANGE_EVENTS=str(self.events), FAKE_RANGE_MODE='valid')
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def download(self, **overrides):
        arguments = dict(url='https://fixture/sdk.tar.zst', destination=self.destination,
                         size=len(self.payload), sha256=self.digest, chunk_size=257,
                         workers=3, timeout=5, curl=[sys.executable, str(self.fake)])
        arguments.update(overrides)
        return self.module.download(**arguments)

    def assert_clean(self):
        self.assertEqual(sorted(self.output.iterdir()), [self.destination], 'range/staging files leaked')

    def assert_failed(self, mode, **overrides):
        with patch.dict(os.environ, FAKE_RANGE_MODE=mode):
            with self.assertRaises(RuntimeError, msg=mode):
                self.download(**overrides)
        self.assertEqual(self.destination.read_bytes(), self.previous, mode + ': old target changed')
        self.assert_clean()

    def test_valid_parallel_ranges_and_last_partial_chunk(self):
        self.download()
        self.assertEqual(self.destination.read_bytes(), self.payload)
        self.assert_clean()
        starts = [json.loads(p.read_text()) for p in self.events.glob('*-start.json')]
        ends = [json.loads(p.read_text()) for p in self.events.glob('*-end.json')]
        expected = [(start, min(start + 256, len(self.payload) - 1)) for start in range(0, len(self.payload), 257)]
        self.assertEqual(sorted((v['start'], v['end']) for v in starts), expected)
        timeline = sorted([(v['at'], 1) for v in starts] + [(v['at'], -1) for v in ends])
        active = peak = 0
        for _, change in timeline:
            active += change
            peak = max(active, peak)
        self.assertGreaterEqual(peak, 2, 'workers were not concurrent')
        self.assertLessEqual(peak, 3, 'configured worker limit exceeded')

    def test_redirect_uses_final_headers(self):
        with patch.dict(os.environ, FAKE_RANGE_MODE='redirectgood'):
            self.download()
        self.assertEqual(self.destination.read_bytes(), self.payload)
        self.assert_clean()

    def test_invalid_final_redirect_headers_rejected(self):
        self.assert_failed('redirectbad')

    def test_prior_range_header_cannot_supply_missing_final_range(self):
        self.assert_failed('redirectmissing')

    def test_http200_is_not_a_range_response(self):
        self.assert_failed('http200')

    def test_wrong_content_range_rejected(self):
        self.assert_failed('wrongrange')

    def test_wrong_content_range_total_rejected(self):
        self.assert_failed('wrongtotal')

    def test_missing_content_range_rejected(self):
        self.assert_failed('missingrange')

    def test_short_body_rejected(self):
        self.assert_failed('shortbody')

    def test_corrupt_body_fails_full_checksum(self):
        self.assert_failed('corrupt')

    def test_curl_failure_with_partial_output_rejected(self):
        self.assert_failed('curlerror')

    def test_deadline_kills_transport_and_cleans_staging(self):
        started = time.monotonic()
        self.assert_failed('deadline', timeout=0.5, workers=1)
        self.assertLess(time.monotonic() - started, 3, 'deadline waited for sleeping transport')
        records = [json.loads(p.read_text()) for p in self.events.glob('*-start.json')]
        self.assertTrue(records, 'deadline case never launched a real transport')
        until = time.monotonic() + 1
        while any(process_alive(v['pid']) for v in records) and time.monotonic() < until:
            time.sleep(0.01)
        self.assertFalse(any(process_alive(v['pid']) for v in records), 'timed out transport remained alive')

    def test_invalid_size_and_hash_fail_before_transport(self):
        for overrides in [dict(size=0), dict(size=-1), dict(size=1.5), dict(size=True),
                          dict(sha256='no'), dict(sha256='g' * 64), dict(sha256='a' * 63)]:
            with self.subTest(overrides=overrides):
                with self.assertRaises(ValueError):
                    self.download(**overrides)
                self.assertEqual(self.destination.read_bytes(), self.previous)
                self.assert_clean()
                self.assertFalse(list(self.events.iterdir()), 'invalid input invoked curl')

    def test_unsafe_url_fails_before_transport(self):
        for url in ['file:///tmp/sdk', 'ftp://fixture/sdk', 'http://untrusted.example/sdk']:
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    self.download(url=url)
                self.assertEqual(self.destination.read_bytes(), self.previous)
                self.assert_clean()
                self.assertFalse(list(self.events.iterdir()), 'unsafe URL invoked curl')


if __name__ == '__main__':
    unittest.main(verbosity=2)
