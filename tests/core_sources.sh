#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$WORK_DIR/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export CORE_SOURCE_TEST="$WORK_DIR"
mkdir -p "$TRAFIRA_LIB/singbox" "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.download_components_via_proxy=1\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$TRAFIRA_LIB/singbox/runtime.uc" <<'UC'
print("127.0.0.1:4535");
UC
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CORE_SOURCE_TEST/requests"
[ ! -e "$CORE_SOURCE_TEST/fail" ] || exit 7
target=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; target=$1; fi
  shift
done
[ -n "$target" ] || exit 1
cp "$CORE_SOURCE_TEST/releases.json" "$target"
SH
cat >"$WORK_DIR/bin/apk" <<'SH'
#!/bin/sh
[ "$1" = query ] || exit 1
printf '%s' '[{"name":"sing-box","version":"1.14.2-r1","arch":"aarch64"}]'
SH
chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/apk"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/releases.json" <<'JSON'
[{"tag_name":"v1.14.2","assets":[{"name":"sing-box-extended_1.14.2_openwrt_aarch64.apk","size":200,"browser_download_url":"https://github.com/shtorm-7/sing-box-extended/releases/download/v1.14.2/sing-box-extended_1.14.2_openwrt_aarch64.apk"}]}]
JSON
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),s=require("components.core_sources");
let env={variant:"extended",architecture:"aarch64",package_type:"apk"},root=getenv("CORE_SOURCE_TEST");
assert(length(s.fetch(env))==1,"bounded release fetch");
assert(index(fs.readfile(root+"/requests"),"http://127.0.0.1:4535")>=0,"configured component transport used");
fs.writefile(root+"/requests","");fs.writefile(root+"/fail","1");
assert(s.fetch(env)==null,"failed proxy is not bypassed");
assert(length(filter(split(fs.readfile(root+"/requests"),"\n"),(line)=>length(line)>0))==1,"no implicit direct retry");
let packages=s.fetch({...env,variant:"stable"});
assert(length(packages)==1 && packages[0].version=="1.14.2-r1","repository versions queried");
print("core version source transport checks passed\n");
'
