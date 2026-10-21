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
let repositories='[]',simulated=0,plan='(1/1) Upgrading sing-box-extended (old -> new)\nOK: 136.6 MiB in 239 packages\n';
Object.assign(ctx,{json:JSON.parse,type:x=>Array.isArray(x)?'array':typeof x,length:x=>x.length,
 command_output_from_args:()=>repositories,ram_prepare_failure:()=>null,command_output:()=>{simulated++;return plan},updates_log:()=>{},trim:s=>s.trim(),split:(s,x)=>s.split(x),match:(s,r)=>s.match(r)});
vm.runInContext(body('isolated_apk_plan_is_core_only')+'\n'+body('isolated_apk_update_ready'),ctx);
assert(ctx.isolated_apk_update_ready('/tmp/new.apk'));assert.equal(simulated,1);
repositories='[{"name":"available-package"}]';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'));assert.equal(simulated,1);
repositories='malformed';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'));
repositories='[]';plan='(1/2) Purging ca-bundle (old)\n(2/2) Upgrading sing-box-extended (old -> new)\nOK: 136.6 MiB in 238 packages\n';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'),'successful solver removing dependency must abort');
plan='unexpected output';assert(!ctx.isolated_apk_update_ready('/tmp/new.apk'));

for(const operation of ['Upgrading','Downgrading','Reinstalling'])assert(ctx.isolated_apk_plan_is_core_only(`(1/1) ${operation} sing-box-extended (version)\nOK: 136.6 MiB in 239 packages\n`));
for(const bad of ['', 'OK: 1 MiB in 1 packages\n', '(1/1) Installing other-package (1)\nOK: 1 MiB in 1 packages\n', '(1/1) Upgrading sing-box-extended (old -> new)\n(2/2) Purging ca-bundle (old)\nOK: 1 MiB in 1 packages\n'])assert(!ctx.isolated_apk_plan_is_core_only(bad));
let staged=0;
Object.assign(ctx,{rollback_package:null,rollback_package_files:[],rollback_packages:[],rollback_apk_world:null,
 sprintf:(_f,x)=>JSON.stringify(x),retain_rollback_files:false,isolated_extended_apk_update:true,tmp_dir:'/tmp/private',
 fs:{readfile:()=> 'sing-box-extended\n'},is_apk:()=>true,installed_package_version:()=> 'old',
 init_tmp_dir:()=>true,ensure_dir:()=>true,write_file:()=>true,
 rollback_installed_packages:()=>{throw Error('unchanged dependencies must not require old archives')},
 stage_rollback_archive:(name,version)=>{staged++;return {name,version,path:'/tmp/old.apk',size:100}},ensure_install_storage:()=>{}});
vm.runInContext(body('stage_previous_sing_box_package'),ctx);
assert(ctx.stage_previous_sing_box_package('extended','install'));assert.equal(staged,1);assert.equal(ctx.rollback_packages.length,1);

let removed=0,restored=0;
Object.assign(ctx,{isolated_extended_apk_update:true,rollback_package:{name:'sing-box-extended',version:'old'},rollback_package_files:['/tmp/old.apk'],
 sing_box_variant_is_package_managed:()=>true,file_nonempty:()=>true,rollback_files_valid:()=>true,
 prepare_sing_box_package_service_install:()=>{},pkg_remove_sing_box_conflict:()=>{removed++;return true},
 pkg_install_rollback_files:()=>{restored++;return true},installed_package_version:()=> 'old'});
vm.runInContext(body('restore_sing_box_package_variant'),ctx);
assert(ctx.restore_sing_box_package_variant('extended'));assert.equal(removed,0,'never uninstall core/dependencies during isolated rollback');assert.equal(restored,1);
console.log('isolated APK repository/dependency and rollback checks passed');
JS
