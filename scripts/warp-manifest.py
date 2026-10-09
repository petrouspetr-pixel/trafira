#!/usr/bin/env python3
"""Build or merge a release manifest from the verified SDK package metadata."""
import hashlib
import io
import json
import re
import sys
import tarfile
from pathlib import Path
NAMES = {"luci-app-trafira-warp", "trafira-warp-awg", "trafira-warp-scout"}
def create(root, version, manager):
    packages = []
    for name in sorted(NAMES):
        text = (root / (name + ".metadata.txt")).read_text()
        def field(key):
            match = re.search(r"^\s*" + re.escape(key) + r": (.+)$", text, re.M)
            if not match:
                raise ValueError("Missing metadata: " + key)
            return match[1].strip()
        apk = manager == "apk"
        assert field("name" if apk else "Package") == name
        release = field("version" if apk else "Version")
        arch = field("arch" if apk else "Architecture")
        assert arch == "aarch64_cortex-a53"
        files = list(root.glob(name + ("-[0-9]*.apk" if apk else "_*.ipk")))
        assert len(files) == 1, (name, files)
        file = files[0]
        installed = int(field("installed-size" if apk else "Installed-Size"))
        if not apk:
            with tarfile.open(file) as outer:
                member = next(m for m in outer if m.name.lstrip("./") == "data.tar.gz")
                with tarfile.open(fileobj=io.BytesIO(outer.extractfile(member).read())) as data:
                    installed = max(installed, sum(m.size for m in data))
        packages.append(dict(name=name, version=release, arch=arch, manager=manager,
                             file=file.name, sha256=hashlib.sha256(file.read_bytes()).hexdigest(),
                             size=file.stat().st_size, installed_size=installed))
    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
    manifest = dict(schema=1, family_version=version, minimum_trafira_version=version, packages=packages)
    (root / ("warp-manifest-" + manager + ".json")).write_text(json.dumps(manifest, indent=2) + "\n")
def merge(output, inputs):
    import shutil
    manifests = [json.loads((d / ("warp-manifest-" + manager + ".json")).read_text()) for manager, d in zip(["opkg", "apk"], inputs)]
    assert manifests[0]['family_version'] == manifests[1]['family_version']
    merged = {**manifests[0], 'packages': manifests[0]['packages'] + manifests[1]['packages']}
    for manager, directory, manifest in zip(['opkg', 'apk'], inputs, manifests):
        assert {p['name'] for p in manifest['packages']} == NAMES
        for package in manifest['packages']:
            assert package['manager'] == manager
            assert Path(package['file']).name == package['file']
            file = directory / package['file']
            assert hashlib.sha256(file.read_bytes()).hexdigest() == package['sha256']
            shutil.copy2(file, output / file.name)
    (output / 'warp-manifest.json').write_text(json.dumps(merged, indent=2) + "\n")
    files = sorted(p for p in output.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
    (output / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in files))
if __name__ == '__main__':
    if sys.argv[1] == 'merge':
        merge(Path(sys.argv[2]), list(map(Path, sys.argv[3:5])))
    else:
        create(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
