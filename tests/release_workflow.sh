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
