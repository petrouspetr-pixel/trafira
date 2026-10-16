#!/usr/bin/env python3
"""Reduce build artifacts with standard DEFLATE; never modify installed files."""
import copy
import gzip
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import zlib


def zopfli_compress(data, kind):
    if kind not in ('gzip', 'deflate'):
        raise ValueError('Unsupported compression container')
    with tempfile.TemporaryDirectory(prefix='trafira-compress-') as directory:
        source = Path(directory) / 'input'
        source.write_bytes(data)
        return subprocess.run(['zopfli', '--i5', '--' + kind, '-c', str(source)],
                              check=True, stdout=subprocess.PIPE).stdout


def inflate(data):
    codec = zlib.decompressobj(-15)
    result = codec.decompress(data) + codec.flush()
    if not codec.eof or codec.unused_data or codec.unconsumed_tail:
        raise ValueError('Invalid or trailing DEFLATE data')
    return result


def recompress_bytes(original, suffix, compressor=zopfli_compress):
    try:
        if suffix == '.apk':
            if original[:4] != b'ADBd':
                raise ValueError('Expected a DEFLATE APK v3 package')
            payload = inflate(original[4:])
            encoded = compressor(payload, 'deflate')
            if inflate(encoded) != payload:
                raise ValueError('APK contents changed during compression')
            return b'ADBd' + encoded
        if suffix != '.ipk':
            raise ValueError('Expected an APK or IPK build artifact')
        with tarfile.open(fileobj=io.BytesIO(original), mode='r:gz') as archive:
            members = archive.getmembers()
            names = [item.name.removeprefix('./') for item in members]
            if (len(names) != 3 or set(names) != {'debian-binary', 'data.tar.gz', 'control.tar.gz'}
                    or any(not item.isfile() for item in members)):
                raise ValueError('Unexpected IPK container members')
            data = [archive.extractfile(item).read() for item in members]
        index = names.index('data.tar.gz')
        payload = gzip.decompress(data[index])
        data[index] = compressor(payload, 'gzip')
        if gzip.decompress(data[index]) != payload:
            raise ValueError('IPK contents changed during compression')
        # Control scripts and both inner tar streams remain byte-for-byte intact.
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w', format=tarfile.GNU_FORMAT) as archive:
            for item, content in zip(members, data):
                item = copy.copy(item)
                item.size = len(content)
                archive.addfile(item, io.BytesIO(content))
        return gzip.compress(stream.getvalue(), compresslevel=9, mtime=0)
    except (OSError, tarfile.TarError, zlib.error, EOFError) as error:
        raise ValueError('Invalid package or compression stream') from error


def recompress_file(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('Expected a regular build artifact')
    original = path.read_bytes()
    result = recompress_bytes(original, path.suffix)
    if len(result) >= len(original):
        print(f'{path.name}: original compression retained ({len(original)} bytes)')
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=path.name + '.', dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(result)
        temporary.chmod(stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f'{path.name}: {len(original)} -> {len(result)} bytes; installed data unchanged')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: recompress-package.py <backend.apk|backend.ipk>')
    recompress_file(sys.argv[1])
