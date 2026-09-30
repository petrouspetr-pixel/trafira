#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
export DOWNLOAD_LOG="$WORK_DIR/requests"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DOWNLOAD_LOG"
exit "${DOWNLOAD_EXIT:-0}"
SH
cp "$WORK_DIR/bin/curl" "$WORK_DIR/bin/wget"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/sleep"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/test.uc" <<'UC'
let as_string = v => v == null ? "" : "" + v;
let shell_quote = v => "'" + replace(as_string(v), "'", "'\\''") + "'";
let command_from_args = args => join(" ", map(args, shell_quote));
let command_success = command => system(command) == 0;
let command_success_from_args = args => command_success(command_from_args(args));
let log_message = (message, level) => null;
UC
sed -n '/^function download_to_file(/,/^}/p' "$ROOT_DIR/trafira/files/usr/lib/components/updates.uc" >>"$WORK_DIR/test.uc"
printf '\nexit(download_to_file(ARGV[0], ARGV[1], ARGV[2]) ? 0 : 1);\n' >>"$WORK_DIR/test.uc"
ucode "$WORK_DIR/test.uc" https://example.com/list "$WORK_DIR/list" ''
grep -Eq -- '--max-time [1-9][0-9]*' "$DOWNLOAD_LOG"
grep -Fq -- '--fail' "$DOWNLOAD_LOG"
grep -Fq -- '--connect-timeout' "$DOWNLOAD_LOG"
ucode "$WORK_DIR/test.uc" https://example.com/list "$WORK_DIR/list" 127.0.0.1:1604
grep -Fq -- '--proxy http://127.0.0.1:1604' "$DOWNLOAD_LOG"
: >"$DOWNLOAD_LOG"
if DOWNLOAD_EXIT=28 ucode "$WORK_DIR/test.uc" https://example.com/list "$WORK_DIR/list" ''; then
  printf 'FAIL: timed out downloads reported success\n' >&2
  exit 1
fi
[ "$(wc -l <"$DOWNLOAD_LOG")" -eq 3 ]
printf 'List download deadline checks passed\n'
