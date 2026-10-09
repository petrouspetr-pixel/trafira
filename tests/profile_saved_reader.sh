#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export PROFILE_READER_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/lib" "$WORK_DIR/stage"
printf "config settings 'settings'\n\toption password 'private'\n" >"$WORK_DIR/current"
cat >"$WORK_DIR/lib/uci.uc" <<'UC'
let fs=require("fs");
return {cursor:(configdir,savedir)=>{
 assert(configdir==getenv("PROFILE_READER_TEST")+"/stage/read","isolated UCI config directory");
 assert(savedir==configdir+"/saved","isolated pending UCI changes");
 assert(fs.readfile(configdir+"/trafira")==fs.readfile(getenv("PROFILE_READER_TEST")+"/current"),"exact saved file copied");
 return {load:(name)=>name=="trafira",foreach:(name,kind,cb)=>{
  assert(kind==null,"all section types must be checked rather than silently dropped");
  cb({".name":"settings",".type":"settings",password:"private"});
 },unload:()=>true};
}};
UC
ucode -L "$WORK_DIR/lib" -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let r=require("config.profile_runtime");
let base=getenv("PROFILE_READER_TEST");
let result=r.read_document(base+"/current",base+"/stage","Saved");
assert(result.success && result.document.name=="Saved" && result.document.config[0].password=="private","saved profile exported");
assert(!r.read_document(base+"/missing",base+"/stage","Missing").success,"missing config rejected");
'
test "$(stat -c %a "$WORK_DIR/stage/read/trafira")" = 600
printf 'saved profile reader isolation checks passed\n'
