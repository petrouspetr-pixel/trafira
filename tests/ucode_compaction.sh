#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_UCODE=1 python3 -B "$ROOT_DIR/tests/test_ucode_compaction.py"
printf 'Installed ucode source compaction checks passed\n'
