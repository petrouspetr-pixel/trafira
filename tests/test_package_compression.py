"""Build-host checks: recompression must never alter package payload bytes."""
import gzip
import importlib.util
import io
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_compression', ROOT / 'tools/recompress-package.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def compress(data, kind):
    if kind == 'gzip':
        return gzip.compress(data, compresslevel=9, mtime=0)
    codec = zlib.compressobj(9, zlib.DEFLATED, -15)
    return codec.compress(data) + codec.flush()


def ipk(members=None):
    if members is None:
        members = [('debian-binary', b'2.0\n'),
                   ('data.tar.gz', gzip.compress(b'payload\n' * 10000, compresslevel=1)),
                   ('control.tar.gz', gzip.compress(b'control and lifecycle hooks'))]
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.GNU_FORMAT) as archive:
        for name, data in members:
            item = tarfile.TarInfo(name)
            item.mode = 0o644
            item.mtime = 123456
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), compresslevel=1)


def entries(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        return {m.name: (m.mode, m.uid, m.gid, m.mtime, archive.extractfile(m).read()) for m in archive}


class CompressionTests(unittest.TestCase):
    def test_apk_keeps_entire_adb_stream(self):
        payload = b'ADBc\x00\x01metadata, signatures, hooks and files\n' * 10000
        codec = zlib.compressobj(1, zlib.DEFLATED, -15)
        original = b'ADBd' + codec.compress(payload) + codec.flush()
        result = module.recompress_bytes(original, '.apk', compress)
        self.assertLess(len(result), len(original))
        self.assertEqual(zlib.decompress(result[4:], -15), payload)

    def test_ipk_keeps_inner_tar_and_control_exactly(self):
        original = ipk()
        result = module.recompress_bytes(original, '.ipk', compress)
        self.assertLess(len(result), len(original))
        before, after = entries(original), entries(result)
        self.assertEqual(before.keys(), after.keys())
        for name in before:
            self.assertEqual(before[name][:4], after[name][:4])
            if name == 'data.tar.gz':
                self.assertEqual(gzip.decompress(before[name][4]), gzip.decompress(after[name][4]))
            else:
                self.assertEqual(before[name][4], after[name][4])

    def test_rejects_unsupported_or_malformed_input(self):
        for data, suffix in [(b'ADBeinvalid', '.apk'), (b'ADBdinvalid', '.apk'),
                             (b'invalid', '.ipk'), (ipk(), '.zip')]:
            with self.subTest(suffix=suffix, data=data[:12]), self.assertRaises(ValueError):
                module.recompress_bytes(data, suffix, compress)

    def test_rejects_trailing_apk_data(self):
        raw = b'ADBd' + compress(b'ADBc payload', 'deflate') + b'unexpected'
        with self.assertRaises(ValueError):
            module.recompress_bytes(raw, '.apk', compress)

    def test_rejects_changed_data_from_compressor(self):
        wrong = lambda data, kind: compress(b'changed', kind)
        for raw, suffix in [(b'ADBd' + compress(b'original', 'deflate'), '.apk'), (ipk(), '.ipk')]:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                module.recompress_bytes(raw, suffix, wrong)

    def test_rejects_unknown_duplicate_or_missing_ipk_members(self):
        for members in [[('unknown', b'bytes')], [('data.tar.gz', b'bad')] * 2,
                        [('debian-binary', b'2.0\n')]]:
            with self.subTest(members=members), self.assertRaises(ValueError):
                module.recompress_bytes(ipk(members), '.ipk', compress)

    def test_preserves_original_if_smaller_or_compression_fails(self):
        with tempfile.TemporaryDirectory(prefix='trafira-package-test-') as directory:
            path = Path(directory) / 'trafira.ipk'
            original = ipk()
            path.write_bytes(original)
            with patch.object(module, 'recompress_bytes', return_value=original + b'larger'):
                module.recompress_file(path)
            self.assertEqual(path.read_bytes(), original)
            with patch.object(module, 'recompress_bytes', side_effect=ValueError('invalid')):
                with self.assertRaises(ValueError):
                    module.recompress_file(path)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_atomic_failure_keeps_original_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory(prefix='trafira-package-test-') as directory:
            path = Path(directory) / 'trafira.ipk'
            original = ipk()
            path.write_bytes(original)
            with patch.object(module, 'recompress_bytes', return_value=b'smaller'), \
                    patch.object(module.os, 'replace', side_effect=OSError('fixture')):
                with self.assertRaises(OSError):
                    module.recompress_file(path)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_real_zopfli_cli(self):
        if not shutil.which('zopfli'):
            if os.environ.get('REQUIRE_ZOPFLI') == '1':
                self.fail('CI must test the actual build-host zopfli executable')
            self.skipTest('zopfli CLI not installed on this host')
        for kind in ('gzip', 'deflate'):
            data = b'backend configuration and code\n' * 1000
            result = module.zopfli_compress(data, kind)
            decoded = gzip.decompress(result) if kind == 'gzip' else zlib.decompress(result, -15)
            self.assertEqual(decoded, data)


if __name__ == '__main__':
    unittest.main()
