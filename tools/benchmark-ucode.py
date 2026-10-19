#!/usr/bin/env python3
"""Compare temporary source/bytecode copies; never modify installed files."""
import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=15)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    source = repo / 'trafira/files/usr/lib'
    with tempfile.TemporaryDirectory(prefix='trafira-bytecode-bench-') as tmp:
        root = Path(tmp)
        staged = root / 'staged'
        shutil.copytree(source, staged / 'usr/lib')
        subprocess.run(['python3', str(repo / 'trafira/compact-sources.py'), str(staged)], check=True, capture_output=True)
        trees = {}
        for kind in ['source', 'bytecode']:
            tree = root / kind
            shutil.copytree(staged / 'usr/lib', tree)
            trees[kind] = tree
        for file in trees['bytecode'].rglob('*.uc'):
            output = file.with_suffix('.ucb')
            subprocess.run(['ucode', '-s', '-cno-interp', '-o', str(output), str(file)], check=True, capture_output=True, timeout=30)
            output.replace(file)
        report = {'environment': 'GitHub Linux runner, warm OS file cache; not a router benchmark', 'iterations': args.iterations, 'variants': {}}
        expected = None
        for kind, tree in trees.items():
            files = sorted(tree.rglob('*.uc'))
            payload = b''.join(file.read_bytes() for file in files)
            env = dict(os.environ, TRAFIRA_LIB=str(tree), TRAFIRA_VERSION='benchmark', TRAFIRA_UCI_STATE_FILE=str(root / 'uci.state'))
            (root / 'uci.state').write_text('trafira.settings=settings\n')
            command = ['ucode', '-L', str(tree), str(tree / 'diagnostics/runtime.uc'), 'show-version']
            result = subprocess.run(command, env=env, capture_output=True, check=True, timeout=15)
            if expected is None:
                expected = result.stdout
            if result.stdout != expected:
                raise RuntimeError('Source/bytecode outputs differ')
            times, rss = [], []
            for _ in range(args.iterations):
                start = time.perf_counter()
                subprocess.run(['/usr/bin/time', '-f', '%M', '-o', str(root / 'rss'), *command], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=15)
                times.append(1000 * (time.perf_counter() - start))
                rss.append(int((root / 'rss').read_text().strip()))
            report['variants'][kind] = {'files': len(files), 'payload_bytes': len(payload), 'payload_gzip_bytes': len(gzip.compress(payload)), 'median_start_ms': round(statistics.median(times), 3), 'max_rss_kib': max(rss)}
        # Measure the actual dispatcher too; full-library bytecode above is
        # an upper bound, not the expected benefit of the bounded entry cache.
        with tempfile.TemporaryDirectory(prefix='trafira-bytecode-test-benchmark-') as directory:
            cache_root = Path(directory)
            (cache_root / '.trafira-bytecode-cache-test').touch()
            (cache_root / 'meminfo').write_text('MemAvailable: 64000 kB\n')
            env = dict(os.environ, TRAFIRA_LIB=str(trees['source']), TRAFIRA_VERSION='benchmark', TRAFIRA_BYTECODE_TEST_ROOT=directory)
            command = ['ucode', str(repo / 'trafira/files/usr/bin/trafira'), 'show_version']
            integrated = {}
            for label, enabled in [('disabled', '0'), ('warm', '1')]:
                current_env = dict(env, TRAFIRA_BYTECODE_CACHE=enabled)
                start = time.perf_counter()
                first = subprocess.run(command, env=current_env, capture_output=True, check=True, timeout=15)
                cold = 1000 * (time.perf_counter() - start)
                if first.stdout != expected:
                    raise RuntimeError('Cached dispatcher output differs')
                elapsed, rss = [], []
                for _ in range(args.iterations):
                    start = time.perf_counter()
                    subprocess.run(['/usr/bin/time', '-f', '%M', '-o', str(root / 'rss'), *command], env=current_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=15)
                    elapsed.append(1000 * (time.perf_counter() - start))
                    rss.append(int((root / 'rss').read_text().strip()))
                integrated[label] = {'first_ms': round(cold, 3), 'median_ms': round(statistics.median(elapsed), 3), 'max_rss_kib': max(rss)}
            cached = cache_root / 'cache'
            files = list(cached.glob('*')) if cached.exists() else []
            if not any(file.suffix == '.ucb' for file in files):
                raise RuntimeError('Dispatcher did not create a RAM bytecode entry')
            integrated['cache_payload_bytes'] = sum(file.stat().st_size for file in files if file.is_file())
            report['integrated_dispatch'] = integrated
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
