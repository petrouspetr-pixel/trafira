#!/usr/bin/env python3
"""Build-only indentation compaction, certified by both ucode compilation modes.

Only text is installed. Bytecode is temporary proof, never a package payload.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def compact_indentation(source):
    return re.sub(rb'(?m)^[ \t]+', lambda match: match[0].replace(b'    ', b'\t'), source)


def normalize_proof(code):
    """Ignore ONLY function source byte positions in stripped ucode proofs.

    Layout: ucode program.c write_vallist/write_function/uc_program_write,
    be92ebd706339fd4a848b88ee516b1ac4eb62ef8. Unknown layouts fail closed.
    Constants, instructions, argument/upvalue counts, source indices, flags and
    exception ranges remain byte-for-byte compared. Never install these bytes.
    """
    result = bytearray(code)
    position = 0

    def take(size):
        nonlocal position
        if size < 0 or position + size > len(code):
            raise ValueError('Truncated ucode proof')
        data = code[position:position+size]
        position += size
        return data

    def u32():
        return int.from_bytes(take(4), 'big')

    if take(4) != b'\x1bucb' or u32() != 0:
        raise ValueError('Expected a stripped, headerless ucode proof')
    take(u32() * 8)  # Constant table indices.
    take(u32())      # Constant data, including original strings/regexps.
    count = u32()
    if not count:
        raise ValueError('Missing main function')
    for _ in range(count):
        flags = u32()
        if flags & ~0x8f:  # arrow, vararg, strict, exceptions, module only.
            raise ValueError('Unexpected ucode function flags/debug layout')
        take(8)  # nargs + nupvals (2 each), srcidx (4): all preserved.
        result[position:position+4] = b'\0' * 4
        take(4)  # srcpos is a byte offset, not an execution instruction.
        size = u32()
        take(size + (-size) % 4)  # Instruction vector and alignment.
        if flags & 8:
            take(u32() * 16)  # Exception ranges: from/to/target/slot.
    if position != len(code):
        raise ValueError('Unexpected trailing ucode proof data')
    return bytes(result)


def compile_source(source, strict, compiler, workspace):
    # Use the same filename for both versions, including sourcepath() constants.
    file = workspace/'source.uc'
    output = workspace/'proof.ucb'
    file.write_bytes(source)
    command = [compiler] + (['-S'] if strict else []) + ['-s', '-cno-interp', '-o', str(output), str(file)]
    result = subprocess.run(command, capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(result.stderr.decode('utf-8', errors='replace'))
    code = output.read_bytes()
    if len(code) < 16:
        raise ValueError('Compiler produced an empty/invalid proof')
    return normalize_proof(code)


def verified_source(source, compiler):
    candidate = compact_indentation(source)
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
        elif compact_indentation(original) != original:
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
