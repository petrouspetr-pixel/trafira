"""Package wrappers must preserve the native packager output without rewriting it."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash') if os.name != 'nt' else r'C:/Program Files/Git/bin/bash.exe'


class NativePackageOutput(unittest.TestCase):
    def test_native_artifacts_are_preserved(self):
        source = (ROOT / 'build.sh').read_text(encoding='utf-8')
        functions = ''
        for name in ['build_ipk_package', 'build_apk_package']:
            body = source.split(name + '() {', 1)[1].split('\n}\n', 1)[0]
            functions += name + '() {' + body + '\n}\n'
        with tempfile.TemporaryDirectory(prefix='trafira-native-') as temporary:
            root = Path(temporary)
            (root / 'native').write_bytes(b'native packager output\x00\xff\n')
            script = r'''
set -eu
ROOT_DIR="$1"
cd "$2"
BUILD_DIR="$PWD/build"
RELEASE_VERSION=9.9.9
PROJECT_URL=https://example.invalid
NATIVE="$PWD/native"
make_dir() { mkdir -p "$1"; }
fakeroot() { cp "$NATIVE" "$BUILD_DIR/manual/ipk-trafira/trafira_9.9.9_all.ipk"; }
unshare() {
 while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then cp "$NATIVE" "$2"; return; fi
  shift
 done
 return 1
}
mkdir -p data control scripts
printf payload >data/payload
printf hook >scripts/backend-post-install.sh
'''
            script += functions
            script += r'''
build_ipk_package native-ipkg trafira "$PWD/data" "$PWD/control" "$PWD/result.ipk"
build_apk_package native-apk trafira 9.9.9 description dependencies "$PWD/data" "$PWD/scripts" backend "$PWD/result.apk" maintainer
cmp "$NATIVE" result.ipk
cmp "$NATIVE" result.apk
test "$(cat data/payload)" = payload
test "$(cat scripts/backend-post-install.sh)" = hook
'''
            path = root / 'test.sh'
            path.write_text(script, encoding='utf-8', newline='\n')
            result = subprocess.run([BASH, path.as_posix(), ROOT.as_posix(), root.as_posix()],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == '__main__':
    unittest.main()
