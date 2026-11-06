#!/usr/bin/env bash
# Exercise the production section builder without ever allocating a router-sized
# failure on the CI host. The child may use at most 96 MiB of virtual memory.
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then exit 0; fi
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$root_dir" <<'PY'
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile

lib = Path(sys.argv[1]) / 'trafira/files/usr/lib'

def bounded():
    resource.setrlimit(resource.RLIMIT_AS, (96 << 20, 96 << 20))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.setsid()

with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp)
    nft = p / 'nft'
    nft.write_text("""#!/bin/sh
case "$*" in
    'list table inet Fixture') exit 0 ;;
    'list tables') echo 'table inet Fixture'; exit 0 ;;
    '-j list tables') echo '{"nftables":[{"table":{"family":"inet","name":"Fixture"}}]}'; exit 0 ;;
    '-f -') cat >/dev/null; touch "$APPLIED"; exit 0 ;;
    *) exit 1 ;;
esac
""")
    nft.chmod(0o755)
    logger = p / 'logger'
    logger.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >&2\n')
    logger.chmod(0o755)
    env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], APPLIED=str(p / 'applied'))
    fixture = p / 'section.json'
    fixture.write_text(json.dumps({'section':[{
        '.type':'section', '.name':'vpn', 'enabled':'1', 'action':'proxy',
        'ports':[str(1024 + i * 2) for i in range(100)]
    }]}))
    source, manifest = p / 'source', p / 'manifest.json'
    argv = ['ucode', '-L', str(lib), str(lib / 'nft/apply.uc'),
            'nft-replace-section-subnets-fixture', str(fixture), 'vpn', str(manifest), 'Fixture']

    def run():
        proc = subprocess.Popen(argv, env=env, preexec_fn=bounded, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            out, _ = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise AssertionError('section replacement spent >20s building an oversized product')
        return proc.returncode, out.decode(errors='replace')[-3000:]

    addresses = [f'198.18.{i//256}.{i%256}' for i in range(50000)]
    for kind in ('plain', 'source'):
        manifest.write_text(json.dumps({'section':json.loads(fixture.read_text())['section'][0], 'inputs':[{'kind':kind, 'path':str(source)}]}))
        def write(values):
            source.write_text('\n'.join(values)+'\n' if kind=='plain' else json.dumps({'version':3,'rules':[{'ip_cidr':values}]}))
        write(addresses[:2])
        rc, log = run()
        assert rc == 0 and (p/'applied').exists(), (kind, 'control failed', rc, log)
        (p/'applied').unlink()
        write(addresses)
        assert source.stat().st_size < 1 << 20  # input fits; only output expansion exceeds the limit
        rc, log = run()
        rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        assert rc == 1 and not (p/'applied').exists(), (kind, 'must refuse without nft commit', rc, log)
        assert rss < 64 * 1024, (kind, 'unbounded preflight RSS (KiB)', rss, log)
        assert not any(s in log.lower() for s in ('out of memory','cannot allocate memory','bad_alloc')), (kind, log)
        print(f'{kind}: 50,000 IPs x 100 ports refused without nft mutation; peak child RSS {rss} KiB')
PY
