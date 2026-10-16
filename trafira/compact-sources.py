#!/usr/bin/env python3
"""Build-only indentation removal, certified by both ucode compilation modes.

Only text is installed. Bytecode is temporary proof, never a package payload.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def strip_indentation(source):
    return re.sub(rb'(?m)^[ \t]+', b'', source)


def compile_source(source, strict, compiler, workspace):
    # Use the same filename for both versions, including sourcepath() constants.
    file = workspace/'source.uc'
    output = workspace/'proof.ucb'
    file.write_bytes(source)
    command = [compiler] + (['-S'] if strict else []) + ['-s', '-c', '-o', str(output), str(file)]
    result = subprocess.run(command, capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(result.stderr.decode('utf-8', errors='replace'))
    code = output.read_bytes()
    if len(code) < 16:
        raise ValueError('Compiler produced an empty/invalid proof')
    return code


def verified_source(source, compiler):
    candidate = strip_indentation(source)
    if candidate == source:
        return source
    with tempfile.TemporaryDirectory(prefix='trafira-ucode-proof-') as directory:
        workspace = Path(directory)
        original_code = [compile_source(source, strict, compiler, workspace) for strict in (False, True)]
        try:
            candidate_code = [compile_source(candidate, strict, compiler, workspace) for strict in (False, True)]
        except ValueError:
            return source
        return candidate if original_code == candidate_code else source


def compact_tree(root, compiler):
    root = Path(root)
    files = sorted((root/'usr/lib').rglob('*.uc'))
    files += [root/'usr/bin'/name for name in ('trafira', 'trafira-config', 'trafira-read')
              if (root/'usr/bin'/name).is_file()]
    if not files:
        raise ValueError('No backend sources found')
    stats = {'files': len(files), 'before': 0, 'after': 0, 'changed': 0, 'retained': 0}
    changes = []
    for file in files:
        if file.is_symlink():
            raise ValueError(f'Unexpected source symlink: {file}')
        original = file.read_bytes()
        try:
            compact = verified_source(original, compiler)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            raise ValueError(f'Cannot verify {file.relative_to(root)}: {error}') from error
        stats['before'] += len(original)
        stats['after'] += len(compact)
        if compact != original:
            changes.append((file, compact))
            stats['changed'] += 1
        elif strip_indentation(original) != original:
            stats['retained'] += 1
    # Finish all proofs before changing the staging tree. File modes stay intact.
    for file, content in changes:
        file.write_bytes(content)
    stats['saved'] = stats['before'] - stats['after']
    return stats


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path, help='staged backend root')
    parser.add_argument('--ucode', default='ucode', help='build-host ucode executable')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = compact_tree(args.root, args.ucode)
    print('Verified installed ucode sources:', json.dumps(result, sort_keys=True))
    if args.report:
        args.report.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
