#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT_DIR/tests/issue96_apk_transition.cjs" "$ROOT_DIR/trafira/files/usr/lib/components/action.uc"
node "$ROOT_DIR/tests/issue96_package_lookup.cjs"
