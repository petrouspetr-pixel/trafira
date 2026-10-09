#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FIXTURE="$WORK" TRAFIRA_CONFIG_FILE="$WORK/trafira" TRAFIRA_TRANSACTION_DIR="$WORK/transactions" TRAFIRA_RUNTIME_STATE_DIR="$WORK/runtime" TRAFIRA_WARP_STATE="$WORK/warp-state" TRAFIRA_WARP_RUNTIME="$WORK/warp-run"
mkdir -p "$WORK/lib/config" "$WORK/lib/integrations" "$WORK/runtime"
cat >"$WORK/lib/config/profile_runtime.uc" <<'UC'
let fs=require("fs"),root=getenv("FIXTURE");
function prepare(doc,dir){let path=dir+"/candidate";return {success:fs.writefile(path,doc.text)==length(doc.text),path};}
function hooks(){return {
 validate:()=>true,capture:()=>({running:!!fs.stat(root+"/running"),enabled:false}),
 activate:()=>{fs.writefile(root+"/activated","");return false;},
 restore:(service)=>{fs.writefile(root+"/restored",sprintf("%J",service));return true;}
};}
return {prepare,hooks};
UC
cat >"$WORK/lib/integrations/warp_transport.uc" <<'UC'
return {read:()=>({running:true,https_ok:true,warp:true})};
UC
ucode -L "$WORK/lib" -L "$ROOT/trafira/files/usr/lib" -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let fs=require("fs"),a=require("integrations.warp_attach"),s=require("warp.state"),t=require("service.config_transaction"),l=require("service.operation_lock"),hash=require("singbox.provenance").hash_file;
let root=getenv("FIXTURE"),target=getenv("TRAFIRA_CONFIG_FILE"),original="config settings main\n";
fs.writefile(target,original);s.save(s.DIRECTORY+"/transport.json",{generation:1});
let digest=hash(target),preview={preview_id:"p-test",expected_digest:digest,generation:1,expires_at:clock()[0]+100,action:"attach",document:{text:"config settings changed\n"}},request={action:"attach",preview_id:"p-test",expected_digest:digest};
s.save(s.RUNTIME+"/preview.json",preview);
let lock=l.acquire("warp-test");assert(lock,"outer coordinator lock");
fs.writefile(target,original+"# user edit\n");assert(a.apply(request,s).error=="conflict","stale preview never overwrites a manual edit");
assert(fs.readfile(target)==original+"# user edit\n","manual edit remains");fs.writefile(target,original);
s.save(s.DIRECTORY+"/transport.json",{generation:2});assert(a.apply(request,s).error=="conflict","changed transport rejected");s.save(s.DIRECTORY+"/transport.json",{generation:1});
fs.writefile(root+"/running","");let result=a.apply(request,s);
assert(!result.success && result.restored,sprintf("late core failure rolls back %J",result));
assert(fs.readfile(target)==original && !t.status().recovery_pending,"original UCI and journal restored");
assert(json(fs.readfile(root+"/restored")).running===true,"original service supplied to restore");
fs.unlink(root+"/running");fs.unlink(root+"/activated");result=a.apply(request,s);
assert(result.success && !fs.stat(root+"/activated"),"stopped Trafira stays stopped; no nested lock deadlock");
assert(fs.readfile(target)==preview.document.text,"reviewed candidate committed");l.release(lock);
print("WARP real attachment transaction: stale preview, generation, late failure and stopped state passed\n");
'
