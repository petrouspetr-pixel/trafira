#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" <<'JS'
const assert=require('assert'),vm=require('vm'),source=require('fs').readFileSync(process.argv[2],'utf8');
function body(name){const a=source.indexOf('function '+name+'(');assert(a>=0,name);return source.slice(a,source.indexOf('\nfunction ',a+1)).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
let argv;
const ctx={command_from_args:a=>{argv=a;return a.join(' ')},push:(a,x)=>a.push(x)};
vm.createContext(ctx);vm.runInContext(body('isolated_apk_core_command'),ctx);
ctx.isolated_apk_core_command(['/tmp/old.apk'],false);
for(const flag of ['--no-network','--repositories-file','/dev/null','--force-reinstall'])assert(argv.includes(flag));
assert(!argv.includes('--simulate'));
ctx.isolated_apk_core_command(['/tmp/new.apk'],true);assert(argv.includes('--simulate'));
let repositories='[]',simulated=0;
Object.assign(ctx,{json:JSON.parse,type:x=>Array.isArray(x)?'array':typeof x,length:x=>x.length,
 command_output_from_args:()=>repositories,ram_prepare_failure:()=>null,run_logged:()=>{simulated++;return true}});
vm.runInContext(body('isolated_apk_update_ready'),ctx);
assert(ctx.isolated_apk_update_ready('/tmp/new.apk'));assert.equal(simulated,1);
repositories='[{"name":"available-package"}]';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'));assert.equal(simulated,1);
repositories='malformed';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'));
let removed=0,restored=0;
Object.assign(ctx,{isolated_extended_apk_update:true,rollback_package:{name:'sing-box-extended',version:'old'},rollback_package_files:['/tmp/old.apk'],
 sing_box_variant_is_package_managed:()=>true,file_nonempty:()=>true,rollback_files_valid:()=>true,
 prepare_sing_box_package_service_install:()=>{},pkg_remove_sing_box_conflict:()=>{removed++;return true},
 pkg_install_rollback_files:()=>{restored++;return true},installed_package_version:()=> 'old'});
vm.runInContext(body('restore_sing_box_package_variant'),ctx);
assert(ctx.restore_sing_box_package_variant('extended'));assert.equal(removed,0,'never uninstall core/dependencies during isolated rollback');assert.equal(restored,1);
console.log('isolated APK repository/dependency and rollback checks passed');
JS
