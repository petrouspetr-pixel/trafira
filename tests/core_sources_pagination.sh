#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export CORE_PAGINATION_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.download_components_via_proxy=0\n' >"$TRAFIRA_UCI_STATE_FILE"
node - "$WORK_DIR" <<'JS'
const fs = require('fs'), root = process.argv[2];
// Real releases contain many architecture assets and lengthy release notes.
// Each page fits the response bound; their aggregate intentionally does not.
const releases = Array.from({ length: 6 }, (_, i) => {
  const version = `1.14.${6 - i}-extended-2.7.2`, tag = `v${version}`;
  const name = `sing-box-extended_${version}_openwrt_aarch64.apk`;
  return { tag_name: tag, body: 'x'.repeat(370000), assets: [{ name, size: 200,
    browser_download_url: `https://github.com/shtorm-7/sing-box-extended/releases/download/${tag}/${name}` }] };
});
fs.writeFileSync(`${root}/all.json`, JSON.stringify(releases));
fs.writeFileSync(`${root}/page-1.json`, JSON.stringify(releases.slice(0, 5)));
fs.writeFileSync(`${root}/page-2.json`, JSON.stringify(releases.slice(5)));
if (fs.statSync(`${root}/all.json`).size <= 2097152) throw Error('fixture must reproduce oversized release catalog');
JS
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
target= maximum= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; target=$1 ;;
    --max-filesize) shift; maximum=$1 ;;
    https://*) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$CORE_PAGINATION_TEST/requests"
case "$url" in
  *'per_page=5&page=1') source="$CORE_PAGINATION_TEST/page-1.json" ;;
  *'per_page=5&page=2')
    [ ! -e "$CORE_PAGINATION_TEST/fail-page-2" ] || exit 7
    source="$CORE_PAGINATION_TEST/page-2.json" ;;
  *'per_page=100') source="$CORE_PAGINATION_TEST/all.json" ;;
  *) exit 1 ;;
esac
[ "$(wc -c <"$source")" -le "$maximum" ] || exit 63
cp "$source" "$target"
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),s=require("components.core_sources"),root=getenv("CORE_PAGINATION_TEST");
let env={variant:"extended",architecture:"aarch64",package_type:"apk"};
let fetched=s.fetch(env);
assert(type(fetched)=="array" && length(fetched)==6,"oversized GitHub catalog is loaded through bounded pages");
assert(fetched[0].version=="1.14.6-extended-2.7.2" && fetched[5].version=="1.14.1-extended-2.7.2","available historical versions remain ordered");
assert(length(filter(split(fs.readfile(root+"/requests"),"\n"),(line)=>length(line)>0))==2,"short final page ends enumeration");
fs.writefile(root+"/fail-page-2","1");
assert(s.fetch(env)==null,"later page failure cannot publish a partial catalog");
assert(length(fs.lsdir(getenv("TRAFIRA_RUNTIME_STATE_DIR")))==0,"temporary source responses removed after success and failure");
print("core source pagination checks passed\n");
'
