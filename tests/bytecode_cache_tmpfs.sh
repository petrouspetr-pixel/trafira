#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
UCODE="$(command -v ucode)"
if ! command -v unshare >/dev/null || ! command -v sudo >/dev/null || ! sudo -n unshare --mount --fork true 2>/dev/null; then
  printf 'SKIP: private mount namespace requires root capability\n'
  exit 0
fi
temp_parent="${RUNNER_TEMP:-/var/tmp}"
WORK_DIR="$(mktemp -d "$temp_parent/trafira-real-tmpfs.XXXXXX")"
case "$WORK_DIR" in "$temp_parent"/trafira-real-tmpfs.*) ;; *) exit 1 ;; esac
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/lib"
cp -a "$LIB/." "$WORK_DIR/lib/"
LIB="$WORK_DIR/lib"
sudo -n unshare --mount --fork bash -s -- "$LIB" "$UCODE" "$WORK_DIR" <<'SH'
set -euo pipefail
lib="$1"; compiler="$2"; work="$3"
mount --make-rprivate /
mount -t tmpfs -o size=8m,mode=1777 tmpfs /tmp
unset TRAFIRA_BYTECODE_TEST_ROOT TRAFIRA_BYTECODE_CACHE
expected="$("$compiler" -L "$lib" "$lib/diagnostics/runtime.uc" show-version)"
actual="$("$compiler" -L "$lib" -e 'let c=require("core.bytecode");let s=c.run(ARGV[0],"diagnostics/runtime.uc",["show-version"]);if(s==null)die("production cache did not run");exit(s);' "$lib")"
[ "$actual" = "$expected" ]
[ "$(stat -c %a /tmp/trafira-bytecode)" = 700 ]
[ "$(stat -c %u /tmp/trafira-bytecode)" = 0 ]
[ "$(find /tmp/trafira-bytecode -name '*.ucb' | wc -l)" -eq 1 ]
# A nested bind mount must never turn this RAM cache into a flash writer.
mkdir -m 700 "$work/nonram"
trap 'umount /tmp/trafira-bytecode 2>/dev/null || true; rmdir "$work/nonram"' EXIT
mount --bind "$work/nonram" /tmp/trafira-bytecode
"$compiler" -L "$lib" -e 'let c=require("core.bytecode");if(c.run(ARGV[0],"diagnostics/runtime.uc",["show-version"])!=null)die("non-RAM mount accepted");' "$lib"
[ -z "$(find "$work/nonram" -mindepth 1 -print -quit)" ]
printf 'Production tmpfs and nested non-RAM rejection passed\n'
SH
