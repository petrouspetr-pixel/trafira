"""Installed source compaction must preserve executable code and line numbers."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compact_sources', ROOT/'trafira/compact-sources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CompactionTests(unittest.TestCase):
    def test_candidate_preserves_lines_strings_comments_and_shebang(self):
        source = b'#!/usr/bin/ucode\n\n    // explanation\n    let s = "two  spaces";\n\tprint(s);\n'
        result = module.strip_indentation(source)
        self.assertEqual(result, b'#!/usr/bin/ucode\n\n// explanation\nlet s = "two  spaces";\nprint(s);\n')
        self.assertEqual(result.count(b'\n'), source.count(b'\n'))

    def test_both_compilation_modes_must_match(self):
        with patch.object(module, 'compile_source', side_effect=[b'normal', b'strict'] * 2) as compile_code:
            self.assertEqual(module.verified_source(b'    print(1);\n', 'ucode'), b'print(1);\n')
        self.assertEqual([call.args[1] for call in compile_code.call_args_list], [False, True, False, True])

    def test_changed_literal_or_strict_code_retains_original(self):
        original = b'    print("multiline\n    literal");\n'
        for results in ([b'normal', b'strict', b'changed', b'strict'],
                        [b'normal', b'strict', b'normal', b'changed']):
            with patch.object(module, 'compile_source', side_effect=results):
                self.assertEqual(module.verified_source(original, 'ucode'), original)

    def test_candidate_parse_failure_retains_original(self):
        source = b'    print(1);\n'
        with patch.object(module, 'compile_source', side_effect=[b'normal', b'strict', ValueError('parse')]):
            self.assertEqual(module.verified_source(source, 'ucode'), source)

    def test_invalid_original_is_a_build_failure(self):
        with patch.object(module, 'compile_source', side_effect=ValueError('original parse')):
            with self.assertRaises(ValueError):
                module.verified_source(b'    invalid;', 'ucode')

    def test_tree_leaves_configuration_and_non_ucode_files_untouched(self):
        with tempfile.TemporaryDirectory(prefix='trafira-compact-test-') as directory:
            root = Path(directory)
            lib = root/'usr/lib/trafira/test.uc'
            lib.parent.mkdir(parents=True)
            lib.write_bytes(b'    print(1);\n')
            config = root/'etc/config/trafira'
            config.parent.mkdir(parents=True)
            config.write_bytes(b'    option value "two  spaces"\n')
            with patch.object(module, 'compile_source', return_value=b'code'):
                stats = module.compact_tree(root, 'ucode')
            self.assertEqual(lib.read_bytes(), b'print(1);\n')
            self.assertEqual(config.read_bytes(), b'    option value "two  spaces"\n')
            self.assertEqual(stats['saved'], 4)
            with patch.object(module, 'compile_source') as compiler:
                self.assertEqual(module.compact_tree(root, 'ucode')['saved'], 0)
                compiler.assert_not_called()

    def test_validation_failure_does_not_partially_rewrite_tree(self):
        with tempfile.TemporaryDirectory(prefix='trafira-compact-test-') as directory:
            root = Path(directory)
            paths = [root/'usr/lib/a.uc', root/'usr/lib/b.uc']
            paths[0].parent.mkdir(parents=True)
            for path in paths:
                path.write_bytes(b'    print(1);\n')
            with patch.object(module, 'verified_source', side_effect=[b'print(1);\n', ValueError('bad source')]):
                with self.assertRaises(ValueError):
                    module.compact_tree(root, 'ucode')
            self.assertTrue(all(path.read_bytes() == b'    print(1);\n' for path in paths))

    def require_ucode(self):
        if not shutil.which('ucode'):
            if os.environ.get('REQUIRE_UCODE') == '1':
                self.fail('CI must verify sources with the actual ucode compiler')
            self.skipTest('ucode not installed on this host')

    def test_actual_compiler_and_runtime(self):
        self.require_ucode()
        original = b'    let s = "two  spaces";\n    // keep source line numbers\n    print(s, "\\n", match("https://test/a", /^https?:\\/\\//)[0]);\n'
        compact = module.verified_source(original, 'ucode')
        self.assertLess(len(compact), len(original))
        results = []
        with tempfile.TemporaryDirectory(prefix='trafira-compact-test-') as directory:
            file = Path(directory)/'same.uc'
            for code in (original, compact):
                file.write_bytes(code)
                results.append(subprocess.run(['ucode', str(file)], capture_output=True, check=True).stdout)
        self.assertEqual(results[0], results[1])

    def test_actual_compiler_protects_multiline_literal(self):
        self.require_ucode()
        source = b'    print("first\n    literal");\n'
        self.assertEqual(module.verified_source(source, 'ucode'), source)

    def test_every_current_module_is_checked_and_modes_are_preserved(self):
        self.require_ucode()
        with tempfile.TemporaryDirectory(prefix='trafira-compact-test-') as directory:
            root = Path(directory)/'root'
            shutil.copytree(ROOT/'trafira/files', root)
            before = {p.relative_to(root): (p.read_bytes(), p.stat().st_mode) for p in root.rglob('*') if p.is_file()}
            stats = module.compact_tree(root, 'ucode')
            self.assertGreaterEqual(stats['files'], 107)
            self.assertLessEqual(stats['after'], stats['before'])
            for name, (original, mode) in before.items():
                path = root/name
                self.assertEqual(path.stat().st_mode, mode)
                self.assertEqual(path.read_bytes().count(b'\n'), original.count(b'\n'))
                if path.suffix != '.uc' and name.parts[:2] != ('usr', 'bin'):
                    self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
