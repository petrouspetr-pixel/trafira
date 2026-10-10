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

printf 'release workflow checks passed\n'
