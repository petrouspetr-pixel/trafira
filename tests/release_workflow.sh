#!/usr/bin/env bash
set -eo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/build.yml"

if grep -Fiq 'sourceforge' "$workflow"; then
  echo 'Build workflow must leave SourceForge publication to GitHub Integration' >&2
  exit 1
fi

grep -Fq 'uses: softprops/action-gh-release@v2.4.0' "$workflow"
# Include extensionless assets such as SHA256SUMS in the published release.
grep -Eq '^[[:space:]]*files: ./filtered-bin/release/\*[[:space:]]*$' "$workflow"

# The release must build and publish only the ordinary Trafira package family.
if grep -Eiq 'warp|setup-go|OpenWrt SDK' "$workflow"; then
  echo 'Build workflow must not build or publish the removed WARP component' >&2
  exit 1
fi
grep -Fq './build.sh "$VERSION" "$PWD/filtered-bin/release"' "$workflow"
grep -Fq 'name: release-files-${{ needs.preparation.outputs.version }}' "$workflow"

grep -Eq '^[[:space:]]*draft: true[[:space:]]*$' "$workflow"
grep -Eq '^[[:space:]]*make_latest: false[[:space:]]*$' "$workflow"

# Publishing a tag must not start another build. A same-tag rerun must not
# replace a checked draft or turn an already published release into a draft.
python3 - "$workflow" <<'PY'
import contextlib
import io
import json
import os
import re
import sys
import textwrap
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

workflow = Path(sys.argv[1]).read_text()
events = workflow.split('on:\n', 1)[1].split('\npermissions:', 1)[0].split('\nconcurrency:', 1)[0]
assert re.findall(r'^  ([a-z_]+):', events, re.M) == ['workflow_dispatch'], 'Release builds must only start by workflow_dispatch'
assert 'group: release-${{ inputs.release_tag }}' in workflow
assert 'cancel-in-progress: false' in workflow
assert 'overwrite_files: false' in workflow
step = workflow.split('      - name: Guard existing release\n', 1)[1].split('\n      - name: Release\n', 1)[0]
assert 'GH_TOKEN: ${{ github.token }}' in step
assert 'RELEASE_TAG: ${{ needs.preparation.outputs.version }}' in step
guard = textwrap.dedent(step.split("python3 - <<'PY'\n", 1)[1].rsplit('\n          PY', 1)[0])
code = compile(guard, '<actual release guard>', 'exec')
release = {'id': 123, 'tag_name': '3.1.0', 'draft': False}
other = {'id': 456, 'tag_name': '3.0.0', 'draft': False}
full_page = [dict(other, id=1000+i, tag_name=f'2.0.{i}') for i in range(100)]

def run(responses, allowed):
    pending = list(responses)
    calls = []
    def urlopen(request, timeout):
        calls.append(request.full_url)
        assert request.get_header('Authorization') == 'Bearer fixture-token'
        assert request.full_url == f'https://api.github.com/repos/fixture/repo/releases?per_page=100&page={len(calls)}'
        assert 0 < timeout <= 60
        result = pending.pop(0)
        if isinstance(result, Exception):
            raise result
        return io.BytesIO(result if isinstance(result, bytes) else json.dumps(result).encode())
    output = io.StringIO()
    with patch.dict(os.environ, {'GH_TOKEN': 'fixture-token', 'GITHUB_REPOSITORY': 'fixture/repo', 'RELEASE_TAG': '3.1.0'}), patch.object(urllib.request, 'urlopen', urlopen), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        try:
            exec(code, {'__name__': '__main__'})
            success = True
        except SystemExit as error:
            success = error.code in (None, 0)
    assert success == allowed, (responses, output.getvalue())
    assert calls and not pending, 'Guard did not inspect expected pages'
    assert 'fixture-token' not in output.getvalue()

run([[]], True)
run([[other]], True)
run([[release]], False)
run([[dict(release, draft=True)]], False)
run([full_page, [release]], False)
run([full_page, []], True)
for status in (401, 403, 404, 429, 500):
    run([urllib.error.HTTPError('https://api.github.com', status, 'fixture', {}, None)], False)
run([urllib.error.URLError('offline')], False)
run([TimeoutError('timed out')], False)
for malformed in (b'{broken', {}, [None], [{'id': 1}], [dict(other, draft='false')]):
    run([malformed], False)
print('release trigger and existing-release guard fixtures passed')
PY

# Execute the actual version/tag guard with an isolated Git response fixture.
# It must allow a fresh tag and a matching (including peeled annotated) tag,
# but never attach freshly built packages to another commit's release tag.
version_script=$(awk '
  /        run: \|/ { capture = 1; next }
  capture && /          python3 -/ { exit }
  capture { sub(/^          /, ""); print }
' "$workflow")
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
run_version_guard() (
  export INPUT_VERSION=3.1.0 GITHUB_OUTPUT="$work_dir/output"
  export TEST_TAG_STATE="$1"
  git() {
    case "$*" in
      'rev-parse HEAD') printf 'current-commit\n' ;;
      'show-ref --verify --quiet refs/tags/3.1.0') [ "$TEST_TAG_STATE" != absent ] ;;
      'rev-parse refs/tags/3.1.0^{commit}')
        if [ "$TEST_TAG_STATE" = matching ]; then printf 'current-commit\n'; else printf 'other-commit\n'; fi ;;
      *) printf 'Unexpected git invocation: %s\n' "$*" >&2; return 1 ;;
    esac
  }
  export -f git
  bash -e -c "$version_script"
)
for tag_state in absent matching; do
  : >"$work_dir/output"
  run_version_guard "$tag_state"
  grep -Fxq 'version=3.1.0' "$work_dir/output"
  grep -Fxq 'commitish=current-commit' "$work_dir/output"
done
: >"$work_dir/output"
if run_version_guard different >"$work_dir/rejected" 2>&1; then
  echo 'Build workflow accepted a release tag on another commit' >&2
  exit 1
fi
grep -Fq 'Release tag 3.1.0 points to other-commit' "$work_dir/rejected"
[ ! -s "$work_dir/output" ]

printf 'release workflow checks passed\n'
