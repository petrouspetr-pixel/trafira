#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
RELEASE_VERSION=3.0.2

# Exercise the same staging functions used by both release package formats.
source <(sed -n '/^make_dir() {/,/^}/p; /^normalize_package_root_modes() {/,/^}/p; /^build_backend_root() {/,/^}/p' "$ROOT_DIR/build.sh")

# Record final executable grants as well, since NTFS cannot represent Unix modes.
chmod() {
  command chmod "$@"
  if [ "$1" = 0755 ]; then
    shift
    printf '%s\n' "$@" >>"$WORK_DIR/executable-grants"
  fi
}
build_backend_root "$WORK_DIR/root"

for path in etc/init.d/trafira usr/bin/trafira usr/bin/trafira-config; do
  grep -Fxq "$WORK_DIR/root/$path" "$WORK_DIR/executable-grants" || {
    echo "FAIL: packaged $path lacks executable permission restoration" >&2
    exit 1
  }
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
      [ "$(stat -c %a "$WORK_DIR/root/$path")" = 755 ] || {
        echo "FAIL: packaged $path is not mode 0755" >&2
        exit 1
      }
      ;;
  esac
done

cmp "$ROOT_DIR/trafira/files/usr/share/trafira/gaming-presets.json" \
  "$WORK_DIR/root/usr/share/trafira/gaming-presets.json"
grep -Fq "$RELEASE_VERSION" "$WORK_DIR/root/usr/lib/trafira/core/constants.uc"
printf 'backend package staging checks passed\n'
