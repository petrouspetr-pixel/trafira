#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export CORE_CANDIDATE_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/control" "$WORK_DIR/data/usr/bin" "$WORK_DIR/ipk" "$WORK_DIR/ipk-stage" "$WORK_DIR/apk-stage" "$WORK_DIR/arch-stage" "$WORK_DIR/path-stage" "$WORK_DIR/bin"
printf '#!/bin/sh\necho "sing-box version 1.14.2"\n' >"$WORK_DIR/data/usr/bin/sing-box"
printf 'Package: sing-box\nVersion: 1.14.2-r1\nArchitecture: aarch64\n' >"$WORK_DIR/control/control"
tar -czf "$WORK_DIR/ipk/control.tar.gz" -C "$WORK_DIR/control" ./control
tar -czf "$WORK_DIR/ipk/data.tar.gz" -C "$WORK_DIR/data" ./usr
printf '2.0\n' >"$WORK_DIR/ipk/debian-binary"
tar -czf "$WORK_DIR/valid.ipk" -C "$WORK_DIR/ipk" ./debian-binary ./control.tar.gz ./data.tar.gz
printf 'synthetic APK handled by fixture tool' >"$WORK_DIR/valid.apk"
cat >"$WORK_DIR/apk-metadata" <<'TEXT'
info:
  name: sing-box
  version: 1.14.2-r1
  arch: aarch64
  installed-size: 100
paths:
  - name: usr/bin
    files:
      - name: sing-box
TEXT
cat >"$WORK_DIR/bin/apk" <<'SH'
#!/bin/sh
[ "$1" != --allow-untrusted ] || shift
if [ "$1" = adbdump ]; then cat "$CORE_CANDIDATE_TEST/apk-metadata"; exit 0; fi
[ "$1" = extract ] || exit 1
shift
while [ "$#" -gt 0 ]; do
  if [ "$1" = --destination ]; then shift; destination=$1; fi
  shift
done
printf 'extract\n' >>"$CORE_CANDIDATE_TEST/extractions"
mkdir -p "$destination/usr/bin"
cp "$CORE_CANDIDATE_TEST/data/usr/bin/sing-box" "$destination/usr/bin/sing-box"
SH
chmod +x "$WORK_DIR/bin/apk"
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),s=require("components.core_candidate"),root=getenv("CORE_CANDIDATE_TEST");
let candidate={version:"1.14.2-r1",variant:"stable",architecture:"aarch64",package_type:"ipk"};
assert(s.stage(root+"/valid.ipk",candidate,root+"/ipk-stage").success,"IPK payload staged without maintainer scripts");
candidate.package_type="apk";
assert(s.stage(root+"/valid.apk",candidate,root+"/apk-stage").success,"APK payload staged and binary checked");
assert(s.stage(root+"/valid.apk",{...candidate,architecture:"x86_64"},root+"/arch-stage").error=="package_metadata_mismatch","wrong package architecture rejected before extraction");
let original=fs.readfile(root+"/apk-metadata");
fs.writefile(root+"/apk-metadata",original+"  - name: ../escape\n");
assert(s.stage(root+"/valid.apk",candidate,root+"/path-stage").error=="unsafe_archive","APK traversal metadata rejected before extraction");
assert(fs.readfile(root+"/extractions")=="extract\n","only valid APK extracted");
print("core candidate package checks passed\n");
'

# Older opkg repositories use -N rather than APK's -rN revision suffix.
mkdir -p "$WORK_DIR/ipk-revision-stage"
printf 'Package: sing-box\nVersion: 1.14.2-1\nArchitecture: aarch64\n' >"$WORK_DIR/control/control"
tar -czf "$WORK_DIR/ipk/control.tar.gz" -C "$WORK_DIR/control" ./control
tar -czf "$WORK_DIR/revision.ipk" -C "$WORK_DIR/ipk" ./debian-binary ./control.tar.gz ./data.tar.gz
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let s=require("components.core_candidate"),root=getenv("CORE_CANDIDATE_TEST");
assert(s.stage(root+"/revision.ipk",{version:"1.14.2-1",variant:"stable",repository_package:"sing-box",architecture:"aarch64",package_type:"ipk"},root+"/ipk-revision-stage").success,"opkg revision stripped only for binary comparison");
'
