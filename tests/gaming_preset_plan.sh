#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp -R "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/lib"
export TRAFIRA_LIB="$WORK_DIR/lib" TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_TRANSACTION_DIR="$WORK_DIR/transactions"
export TRAFIRA_GAMING_CATALOG="$ROOT_DIR/trafira/files/usr/share/trafira/gaming-presets.json"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR" "$TRAFIRA_TRANSACTION_DIR"
printf original >"$TRAFIRA_CONFIG_FILE"
printf untouched >"$TRAFIRA_TRANSACTION_DIR/previous.uci"
printf idle >"$TRAFIRA_RUNTIME_STATE_DIR/job.json"
# Poison every forbidden backend path. A planner reaching any of them fails.
for module in config/profile_runtime config/profile_job service/config_transaction service/operation_lock; do
 cat >"$TRAFIRA_LIB/$module.uc" <<'UC'
function forbidden(){die("secret-value-that-must-never-be-returned");}
return {read_document:forbidden,prepare:forbidden,hooks:forbidden,new_directory:forbidden,cleanup:forbidden,status:forbidden,start_document:forbidden,acquire:forbidden,release:forbidden,apply:forbidden};
UC
done
cat >"$TRAFIRA_LIB/diagnostics/alice.uc" <<'UC'
print(sprintf("%J",{devices:[{interface:"br-lan",mac:"02:00:00:00:00:01",ips:["192.0.2.5","2001:db8::5"]}]}));
UC
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),root=process.argv[2];
const sections=[{'.name':'settings','.type':'settings'},{'.name':'vpn','.type':'section',enabled:'1',action:'connection',password:'private-password'}];
const op={action:'upsert',preset:'steam',device_ips:['192.0.2.5/32','2001:db8::5/128'],proxy_section:'vpn',placement:'before-device-routes'};
for(const [name,operations] of [['ok',[op,{...op,preset:'epic'}]],['bad',[op,{...op,preset:'missing'}]],['empty',[]],['bounds',Array(129).fill(op)]])fs.writeFileSync(`${root}/${name}.request`,JSON.stringify({action:'plan',sections,operations}));
JS
for name in ok bad empty bounds; do
 ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/config/gaming_cli.uc" action "$(cat "$WORK_DIR/$name.request")" >"$WORK_DIR/$name.json"
done
node - "$WORK_DIR" <<'JS'
const assert=require('assert'),fs=require('fs'),root=process.argv[2],read=n=>JSON.parse(fs.readFileSync(`${root}/${n}.json`));
const result=read('ok');assert(result.success);assert.equal(result.owners.length,2);assert.equal(result.config.filter(s=>s.preset_owner).length,4);
assert.equal(result.config.find(s=>s['.name']==='vpn').password,'private-password','ordinary values preserved');
assert(read('empty').success);assert.equal(read('empty').config.length,2);
for(const name of ['bad','bounds']){const r=read(name);assert.equal(r.success,false);assert(!r.config,'no partially applied config');assert(!JSON.stringify(r).includes('private-password'));assert(!JSON.stringify(r).includes('secret-value'));}
JS
test "$(cat "$TRAFIRA_CONFIG_FILE")" = original
test "$(cat "$TRAFIRA_TRANSACTION_DIR/previous.uci")" = untouched
test "$(cat "$TRAFIRA_RUNTIME_STATE_DIR/job.json")" = idle
test "$(find "$TRAFIRA_RUNTIME_STATE_DIR" -type f | wc -l)" -eq 1
test "$(find "$TRAFIRA_TRANSACTION_DIR" -type f | wc -l)" -eq 1
printf 'gaming native read-only planning checks passed\n'
