#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_PROFILES_DIR="$WORK_DIR/profiles"
export TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_CONFIG_FILE="$WORK_DIR/config"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
printf current >"$TRAFIRA_CONFIG_FILE"
mkdir -p "$WORK_DIR/shim"
cat >"$WORK_DIR/shim/uci.uc" <<'UC'
return {cursor:()=>({load:()=>true,unload:()=>true,foreach:(package,kind,callback)=>{
 if(kind==null || kind=="settings")callback({".name":"settings",".type":"settings",password:"current-secret"});
}})};
UC
call() { ucode -L "$WORK_DIR/shim" -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/profile_cli.uc" action "$1"; }
call '{"action":"list"}' >"$WORK_DIR/list.json"
call '{"action":"import_begin"}' >"$WORK_DIR/upload.json"
id=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).id)' "$WORK_DIR/upload.json")
payload=$(node -e 'process.stdout.write(Buffer.from(JSON.stringify({schema:1,name:"Imported",config:[{".name":"settings",".type":"settings",password:"secret"}]})).toString("base64"))')
call "{\"action\":\"import_chunk\",\"id\":\"$id\",\"offset\":0,\"data\":\"$payload\"}" >"$WORK_DIR/chunk.json"
call "{\"action\":\"import_chunk\",\"id\":\"$id\",\"offset\":0,\"data\":\"$payload\"}" >"$WORK_DIR/duplicate.json"
call "{\"action\":\"import_finish\",\"id\":\"$id\"}" >"$WORK_DIR/imported.json"
call '{"action":"list"}' >"$WORK_DIR/list.json"
call '{"action":"export_read","id":"../../etc/config/trafira","offset":0}' >"$WORK_DIR/traversal.json"
call '{"action":"status"}' >"$WORK_DIR/status.json"
call 'invalid-json' >"$WORK_DIR/invalid.json"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),p=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${p}/${n}.json`));
if (!read('chunk').success || !read('imported').success) throw Error('import failed');
if (read('duplicate').success || read('traversal').success || read('invalid').success) throw Error('unsafe request accepted');
if (read('list').entries[0].name!=='Imported') throw Error('metadata absent');
for (const n of ['list','status','imported']) if (JSON.stringify(read(n)).includes('secret')) throw Error('secret exposed');
JS
profile=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).id)' "$WORK_DIR/imported.json")
call '{"action":"create","name":"Saved"}' >"$WORK_DIR/created.json"
call "{\"action\":\"preview\",\"id\":\"$profile\"}" >"$WORK_DIR/preview.json"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),p=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${p}/${n}.json`));
if (!read('created').success || !read('preview').success || !read('preview').digest || !read('preview').changes.length) throw Error('create/preview failed');
if (JSON.stringify(read('preview')).includes('secret')) throw Error('preview leaked credentials');
JS
call "{\"action\":\"export_begin\",\"id\":\"$profile\"}" >"$WORK_DIR/export.json"
export_id=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).id)' "$WORK_DIR/export.json")
call "{\"action\":\"export_read\",\"id\":\"$export_id\",\"offset\":0}" >"$WORK_DIR/data.json"
node - "$WORK_DIR/data.json" <<'JS'
const r=JSON.parse(require('fs').readFileSync(process.argv[2]));
if (!r.success || JSON.parse(Buffer.from(r.data,'base64')).config[0].password!=='secret') throw Error('explicit export lost data');
JS
printf 'profile CLI transfer checks passed\n'
