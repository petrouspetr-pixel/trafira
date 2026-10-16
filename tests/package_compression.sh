#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_ZOPFLI=1 python3 "$ROOT_DIR/tests/test_package_compression.py"
grep -Fq 'tools/recompress-package.py' "$ROOT_DIR/build.sh"
printf 'Lossless backend package compression checks passed\n'
