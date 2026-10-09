#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export CORE_CANDIDATE_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/payload" "$WORK_DIR/good" "$WORK_DIR/bad-checksum" "$WORK_DIR/bad-path" "$WORK_DIR/bad-link"
printf '#!/bin/sh\necho "sing-box version 1.14.2"\n' >"$WORK_DIR/payload/sing-box"
printf 'library fixture' >"$WORK_DIR/payload/libcronet.so"
tar -czf "$WORK_DIR/good.tar.gz" -C "$WORK_DIR/payload" sing-box libcronet.so
python3 - "$WORK_DIR" <<'PY'
import io, sys, tarfile
root = sys.argv[1]
with tarfile.open(root + '/bad-path.tar.gz', 'w:gz') as out:
    item = tarfile.TarInfo('../escape'); item.size = 1
    out.addfile(item, io.BytesIO(b'x'))
with tarfile.open(root + '/bad-link.tar.gz', 'w:gz') as out:
    item = tarfile.TarInfo('sing-box'); item.type = tarfile.SYMTYPE; item.linkname = '/bin/sh'
    out.addfile(item)
PY
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),s=require("components.core_candidate"),h=require("singbox.provenance");
let root=getenv("CORE_CANDIDATE_TEST"),file=root+"/good.tar.gz";
let candidate={version:"1.14.2",variant:"extended-compressed",architecture:"aarch64",package_type:"tar.gz",sha256:h.hash_file(file)};
let good=s.stage(file,candidate,root+"/good");
assert(good.success && fs.lstat(good.binary).type=="file" && good.version=="1.14.2","stage selected binary without installation");
assert(s.stage(file,{...candidate,sha256:sprintf("%064d",0)},root+"/bad-checksum").error=="checksum_mismatch","checksum before extraction");
assert(s.stage(root+"/bad-path.tar.gz",{...candidate,sha256:""},root+"/bad-path").error=="unsafe_archive","archive traversal rejected");
assert(!fs.stat(root+"/escape"),"no escape file created");
assert(s.stage(root+"/bad-link.tar.gz",{...candidate,sha256:""},root+"/bad-link").error=="unsafe_archive","archive symlink rejected");
print("core candidate archive checks passed\n");
'
