#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# APK buildroot embeds the hook body into /bin/sh after removing its shebang.
sed -n '/^define Package\/trafira\/prerm$/,/^endef$/p' "$ROOT_DIR/trafira/Makefile" |
  sed '1d;$d;/^#!/d;s/\$\$/\$/g' >"$WORK_DIR/prerm.sh"
sh -n "$WORK_DIR/prerm.sh"
IPKG_INSTROOT="$WORK_DIR/root" sh "$WORK_DIR/prerm.sh" remove
printf 'Package prerm shell compatibility checks passed\n'
