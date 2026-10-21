#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" <<'NODE'
const assert = require('assert');
const vm = require('vm');
const source = require('fs').readFileSync(process.argv[2], 'utf8');
function body(name) {
 const start=source.indexOf('function '+name+'(');assert(start>=0,'Missing function '+name);
 const end=source.indexOf('\nfunction ',start+1);
 return source.slice(start,end<0?source.indexOf('\nlet mode =',start):end).trim().replace(/for \(let (\w+) in /g,'for (let $1 of ');
}
const MiB=1048576;
const base={int: x=>Math.trunc(Number(x)), as_string:x=>x==null?'':String(x),
 file_exists:()=>true, pkg_is_installed:()=>true,
 fs:{lstat:()=>({type:'file',size:100*MiB})},sing_box_runtime_output:()=> 'extended',
 filesystem_available_bytes:()=>Math.floor(13.13*MiB),
 action_fail:(_c,_a,m)=>{throw Error(m)},
 install_storage_error:(p,a,r)=>a<r?'disk full':'',
 install_storage_required_bytes:(_c,n,a)=>Math.max(a==='install_tiny'?8*MiB:32*MiB,n+4*MiB)};
const c=vm.createContext({...base});
vm.runInContext(body('ram_extended_update_eligible')+'\n'+body('ensure_install_storage'),c);
assert(c.ram_extended_update_eligible('sing_box','install'));
assert(c.ram_extended_update_eligible('sing_box','install_extended'));
for(const a of ['install_tiny','install_stable','install_extended_compressed','check_update']) assert(!c.ram_extended_update_eligible('sing_box',a));
c.ensure_install_storage('sing_box','install',0);
c.ram_extended_update=true;
c.ensure_install_storage('sing_box','install',180*MiB); // rollback archives are in RAM
c.ram_extended_update=false;
c.sing_box_runtime_output=()=> 'not-installed';
assert.throws(()=>c.ensure_install_storage('sing_box','install',0),/disk full/);
c.sing_box_runtime_output=()=> 'stable';
assert.throws(()=>c.ensure_install_storage('sing_box','install_extended',0),/disk full/);
c.sing_box_runtime_output=()=> 'extended';c.fs.lstat=()=>({type:'link'});
assert(!c.ram_extended_update_eligible('sing_box','install'));
c.fs.lstat=()=>({type:'file'});c.filesystem_available_bytes=()=>0;
assert.throws(()=>c.ensure_install_storage('sing_box','install',0),/disk full/);
// The RAM path must validate and preserve old files before stopping any service.
const install=body('install_sing_box_extended_package');
assert(install.indexOf('prepare_ram_extended_update')<install.indexOf('stop_trafira_before_sing_box_change'));
assert(install.indexOf('stage_previous_sing_box_package')<install.indexOf('stop_trafira_before_sing_box_change'));

const candidateSource=require('fs').readFileSync(require('path').join(require('path').dirname(process.argv[2]),'core_candidate.uc'),'utf8');
const capStart=candidateSource.indexOf('function stage_capacity(');
assert(capStart>=0,'candidate expansion must check real RAM before extraction');
const capEnd=candidateSource.indexOf('\nfunction ',capStart+1);
const capContext=vm.createContext({fs:{readfile:()=> 'MemAvailable: 65536 kB\n'}, storage:{available_bytes:()=>256*MiB},int:Math.trunc,split:(s,x)=>s.split(x),match:(s,r)=>s.match(r)});
vm.runInContext(candidateSource.slice(capStart,capEnd).replace(/for \(let (\w+) in /g,'for (let $1 of '),capContext);
assert(!capContext.stage_capacity('/tmp',64*MiB));
assert(capContext.stage_capacity('/tmp',16*MiB));
capContext.fs.readfile=()=>'';assert(!capContext.stage_capacity('/tmp',1));

for(const failure of ['same-version', '', 'preflight', 'ram-copy', 'stop', 'install', 'validate', 'start', 'flash', 'dependencies']) {
 const events=[], present=new Set(['/usr/bin/sing-box','/usr/lib/libcronet.so']);
 const saved={files:[{path:'/usr/bin/sing-box',backup:'/tmp/private/ram-core/sing-box.gz'},{path:'/usr/lib/libcronet.so',backup:'/tmp/private/ram-core/libcronet.so.gz'}]};
 let ctx={...base,tmp_dir:'/tmp/private',SERVICE_INIT:'/etc/init.d/test',selected_core:null,ram_extended_update:false,isolated_extended_apk_update:false,
 is_apk:()=>true,isolated_apk_update_ready:()=>failure!=='dependencies',isolated_apk_core_command:()=>'',
 init_tmp_dir:()=>true,sing_box_runtime_output:k=>k==='variant'?'extended':failure==='same-version'?'2.0-extended':'1.0-extended',
 installed_package_version:()=>failure==='same-version'?'2.0-r1':'1.0-r1',
 rollback_archive_field:()=> '2.0-r1',
 resolve_sing_box_extended_release:()=>({tag:'2.0-extended',asset_name:'new.apk',asset_url:'https://example.test/new',asset_size:35*MiB}),
 normalize_sing_box_version:x=>x,ensure_tmp_download_capacity:()=>true,download_with_retry:()=>true,
 pkg_list_update_command:()=>'',run_logged:()=>true,
 prepare_ram_extended_update:()=>{events.push('preflight');return failure==='preflight'?null:saved},
 stage_previous_sing_box_package:()=>{events.push('rollback-package');return true},
 stage_ram_extended_backup:()=>{events.push('ram-copy');return failure!=='ram-copy'},ram_extended_update_unchanged:()=>true,
 updates_log:()=>{},stop_trafira_before_sing_box_change:()=>events.push('stop'),
 ram_extended_flash_reserve:()=>failure!=='flash',
 wait_ram_core_stopped:()=>failure!=='stop',prepare_sing_box_package_service_install:()=>{},
 file_exists:x=>present.has(x),remove_file:x=>{events.push('remove:'+x);present.delete(x)},
 command_success_from_args:()=>true,owner_pid:()=>123,
 move_file_to_backup:()=>{throw Error('must not duplicate flash payload')},
 run_logged_pkg_remove_sing_box_conflict:()=>true,pkg_install_files_command:()=>'',
 run_logged_install:()=>{events.push('install');return failure!=='install'},
 package_failure_message:x=>x,
 restore_sing_box_after_failed_extended_package_install:()=>{events.push('rollback');return true},
 validate_sing_box_extended_binary:()=>failure==='validate'?'':'2.0-extended',
 write_sing_box_variant_state:()=>{},restart_trafira_after_successful_change:()=>events.push('start'),
 wait_trafira_running_after_sing_box_change:()=>failure!=='start',finish_selected_core:()=>true,selected_core_unchanged:()=>true,
 clear_version_caches:()=>{},action_success:()=>{throw Error('success')},
 action_fail:(_c,_a,m)=>{throw Error(m)}
 };
 vm.createContext(ctx);vm.runInContext(body('ram_extended_update_eligible')+'\n'+body('install_sing_box_extended_package'),ctx);
 let outcome='';try{ctx.install_sing_box_extended_package('install')}catch(e){outcome=e.message}
 if(failure==='same-version'){assert.equal(outcome,'success');assert(!events.includes('stop'));assert(!events.includes('install'));}
 else if(!failure){assert.equal(outcome,'success');assert(events.indexOf('ram-copy')<events.indexOf('stop'));assert(events.indexOf('stop')<events.indexOf('remove:/usr/bin/sing-box'));assert(events.indexOf('remove:/usr/bin/sing-box')<events.indexOf('install'));}
 else if(['preflight','ram-copy','stop','dependencies'].includes(failure)) {assert(!events.some(x=>x.startsWith('remove:')));assert(!events.includes('install'));if(failure!=='stop')assert(!events.includes('stop'));}
 else {assert(events.includes('rollback'),failure+' must restore offline');assert.notEqual(outcome,'success');}
}
console.log('limited flash Extended policy and transaction failures passed');
NODE
