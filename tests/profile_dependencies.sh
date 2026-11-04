#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$ROOT_DIR/tests/fixtures/profile_dependencies.uc"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_PROFILES_DIR="$WORK_DIR/profiles"
mkdir -p "$WORK_DIR/shim/service"
cat > "$WORK_DIR/shim/service/operation_lock.uc" <<'LOCK'
return {acquire:()=>die("dependency report must not acquire the configuration lock\n"),release:()=>die("unexpected unlock\n")};
LOCK
profile=$(ucode -L "$TRAFIRA_LIB" -e '
let profiles=require("config.profiles");
let result=profiles.create({schema:1,name:"Private profile",config:[{".name":"settings",".type":"settings",password:"SECRET_NOT_PUBLIC",dns_mtls_enabled:"1",dns_mtls_client_key:"/missing-profile-test-private.pem"}]});
assert(result.success,"profile create");print(result.id);
')
ucode -L "$WORK_DIR/shim" -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/profile_cli.uc" action "{\"action\":\"dependencies\",\"id\":\"$profile\"}" > "$WORK_DIR/report.json"
node - "$WORK_DIR/report.json" <<'CHECK'
const fs=require('fs'), text=fs.readFileSync(process.argv[2],'utf8'), result=JSON.parse(text);
if (!result.success || result.report.schema!==1) throw Error('report endpoint failed');
if (!result.report.files.some(f=>f.path==='/missing-profile-test-private.pem' && f.status==='missing')) throw Error('missing key not listed');
if (text.includes('SECRET_NOT_PUBLIC') || text.includes('Private profile')) throw Error('profile data leaked');
CHECK
printf 'profile dependency endpoint and lock checks passed\n'

python3 - "$ROOT_DIR" <<'LOCALES'
import json
import pathlib
import re
import sys
root=pathlib.Path(sys.argv[1])
source=(root/'fe-app-trafira/src/trafira/tabs/diagnostic/profileDependencies.ts').read_text()
keys=set(re.findall(r"_\(\s*'([^']+)'",source)) | {'Check dependencies','Checking profile dependencies...'}
po=(root/'luci-app-trafira/po/ru/trafira.po').read_text()
for key in keys:
    pattern='msgid '+json.dumps(key,ensure_ascii=False)+'\nmsgstr "'
    assert pattern in po and not (pattern+'"') in po, 'missing Russian dependency caption: '+key
print('dependency report Russian captions passed')
LOCALES
