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

printf 'release workflow checks passed\n'
