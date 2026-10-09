#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"; KIND="${2:-}"; ARCHITECTURE="${3:-}"; OUTPUT="${4:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$ARCHITECTURE" == aarch64_cortex-a53 && -n "$OUTPUT" ]] || { echo 'Usage: build-warp.sh x.y.z opkg|apk aarch64_cortex-a53 output' >&2; exit 2; }
case "$KIND" in
 opkg) RELEASE=24.10.6; GCC=13.3.0; HASH=bf9821b98fe810e2cc3ab53b8faa13bc919b9d98d703cba5e53906c17bd23864; EXT=ipk;;
 apk) RELEASE=25.12.3; GCC=14.3.0; HASH=9f3e2db5d8ee29c0248104d65f0091ef85fad37a11c3d26ad1370a9223965fe7; EXT=apk;;
 *) echo 'Unsupported package manager' >&2; exit 2;;
esac
HOST_GO="$(command -v go)"
CACHE="${WARP_SDK_CACHE:-$HOME/.cache/trafira-warp-sdk}"
mkdir -p "$CACHE" "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
FILE="openwrt-sdk-$RELEASE-mediatek-filogic_gcc-${GCC}_musl.Linux-x86_64.tar.zst"
if [[ ! -f "$CACHE/$FILE" ]]; then
 curl --proto '=https' --proto-redir '=https' -fL --retry 3 --max-time 300 "https://downloads.openwrt.org/releases/$RELEASE/targets/mediatek/filogic/$FILE" -o "$CACHE/$FILE.part"
 printf '%s  %s\n' "$HASH" "$CACHE/$FILE.part" | sha256sum -c -
 mv "$CACHE/$FILE.part" "$CACHE/$FILE"
fi
printf '%s  %s\n' "$HASH" "$CACHE/$FILE" | sha256sum -c -
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
tar --zstd -xf "$CACHE/$FILE" -C "$WORK"
SDK="$WORK/${FILE%.tar.zst}"
cp -R "$ROOT/components/warp" "$SDK/package/trafira-warp"
cp -R "$ROOT/trafira" "$SDK/package/trafira"
sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$VERSION/" "$SDK/package/trafira-warp/luci-app-trafira-warp/Makefile"
cd "$SDK"
./scripts/feeds update -a
./scripts/feeds install -a
printf '%s\n' 'CONFIG_PACKAGE_luci-app-trafira-warp=m' 'CONFIG_PACKAGE_trafira-warp-awg=m' 'CONFIG_PACKAGE_trafira-warp-scout=m' >>.config
make defconfig
for package in trafira-warp-awg trafira-warp-scout luci-app-trafira-warp; do
 make -j2 "package/trafira-warp/$package/compile" V=s TRAFIRA_HOST_GO="$HOST_GO"
done
for package in luci-app-trafira-warp trafira-warp-awg trafira-warp-scout; do
 mapfile -t matches < <(find bin/packages -type f -name "${package}_*.$EXT" -o -type f -name "${package}-[0-9]*.$EXT")
 [[ ${#matches[@]} == 1 ]] || { echo "Expected one artifact for $package, got ${#matches[@]}" >&2; exit 1; }
 cp "${matches[0]}" "$OUTPUT/"
done
cd "$OUTPUT"
sha256sum -- *.$EXT >SHA256SUMS
