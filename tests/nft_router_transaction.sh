#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/bin"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" PATH="$WORK_DIR/bin:$PATH"
printf 'trafira.settings=settings\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
cat >/dev/null
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/fail-nft"
SH
chmod +x "$WORK_DIR/bin/nft"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),origin=require("nft.router_origin"),batch=require("nft.transaction");
let root=getenv("TRAFIRA_RUNTIME_STATE_DIR"),path=root+"/router-origin.json";
let settings={router_origin_enabled:"1",router_origin_section:"vpn"},sections=[{".name":"vpn",action:"connection",enabled:"1"}];
function prepare(t) {
 return origin.install(settings,sections,"Fixture","localv4","localv6","0x04000000",(script,publish)=>t.append(script) && t.after_commit(publish));
}
fs.writefile(path,"old verified state");
let t=batch.create();assert(prepare(t),"router rules can be queued");
assert(fs.readfile(path)=="old verified state","building router rules never publishes candidate state");
fs.writefile(root+"/fail-nft","1");
assert(!t.commit() && fs.readfile(path)=="old verified state","failed nft retains previous router snapshot");
fs.unlink(root+"/fail-nft");t=batch.create();assert(prepare(t) && t.commit(),"successful nft publishes new router snapshot");
assert(json(fs.readfile(path)).section=="vpn","published snapshot belongs to the applied router section");
print("router-origin state follows the nft transaction commit\n");
'
