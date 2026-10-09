#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_PROFILES_DIR="$WORK_DIR/profiles"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/tests/fixtures/config_profiles.uc"
test "$(stat -c %a "$TRAFIRA_PROFILES_DIR")" = 700
find "$TRAFIRA_PROFILES_DIR" -name '*.json' -exec stat -c %a {} \; | while read -r mode; do test "$mode" = 600; done
