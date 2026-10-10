#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
RELEASE_VERSION=3.0.3
source <(sed -n '/^write_release_checksums() {/,/^}/p' "$ROOT_DIR/build.sh")
for name in trafira luci-app-trafira luci-i18n-trafira-ru; do
  for format in apk ipk; do
    printf '%s\n' "$name.$format" >"$WORK_DIR/${name}_${RELEASE_VERSION}.$format"
  done
done
printf 'unrelated file\n' >"$WORK_DIR/old.apk"
write_release_checksums "$WORK_DIR"
[ "$(wc -l <"$WORK_DIR/SHA256SUMS")" -eq 6 ]
! grep -q old.apk "$WORK_DIR/SHA256SUMS"
(cd "$WORK_DIR" && sha256sum -c SHA256SUMS)
printf 'modified\n' >>"$WORK_DIR/trafira_${RELEASE_VERSION}.apk"
if (cd "$WORK_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
  echo 'Modified release package was not rejected' >&2
  exit 1
fi
grep -Fq '  write_release_checksums "$output_dir"' "$ROOT_DIR/build.sh"
printf 'release checksum generation and corruption detection passed\n'
