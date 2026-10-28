const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(process.argv[2]||'trafira/files/usr/lib/components/action.uc','utf8');
function body(name){let a=source.indexOf('function '+name+'(');assert(a>=0,name);let b=source.indexOf('\nfunction ',a+1);return source.slice(a,b<0?undefined:b).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
const ctx={rollback_package:null,rollback_package_files:[],rollback_packages:[],rollback_apk_world:null,retain_rollback_files:false,
 isolated_extended_apk_update:false,tmp_dir:'/tmp/private',fs:{readfile:()=> 'sing-box-extended\n'},
 is_apk:()=>true,installed_package_version:()=> 'old',init_tmp_dir:()=>true,ensure_dir:()=>true,write_file:()=>true,
 sprintf:(_f,x)=>JSON.stringify(x),ensure_install_storage:()=>{},push:(a,x)=>a.push(x),
 rollback_installed_packages:()=>[{name:'sing-box-extended',version:'old'},{name:'ca-bundle',version:'20260601-r1'}],
 stage_rollback_archive:(name,version)=>['sing-box','sing-box-tiny','sing-box-extended'].includes(name)?{name,version,path:'/tmp/old.apk',size:100}:null,
 updates_log:()=>{}};
vm.createContext(ctx);vm.runInContext(body('stage_previous_sing_box_package'),ctx);
assert.equal(ctx.stage_previous_sing_box_package('extended','install',true),true,
 'a verified core-only APK transition must not require the unavailable unchanged ca-bundle archive');
assert.equal(ctx.rollback_packages.length,1);
assert.equal(ctx.stage_previous_sing_box_package('extended','install',false),false,
 'ordinary/unproven transitions still need the exact full rollback closure');
for(const variant of ['stable','tiny'])assert.equal(ctx.stage_previous_sing_box_package(variant,'install',true),true,
 'verified package-managed '+variant+' update must not require an unchanged unavailable dependency');
console.log('issue96 rollback preflight checks passed');

const primitive={as_string:x=>x==null?'':String(x),type:x=>Array.isArray(x)?'array':x===null?'null':typeof x,
 json:JSON.parse,int:x=>Math.trunc(Number(x)),length:x=>x.length,push:(a,x)=>a.push(x),join:(sep,a)=>a.join(sep),
 split:(s,sep)=>s.split(sep),trim:s=>s.trim(),match:(s,r)=>s.match(r)};
const functions=['apk_transition_command','apk_transition_plan_safe','apk_transition_dependencies_unchanged',
 'apk_transition_world','write_apk_transition_world','apk_transition_ready','apply_apk_core_transition',
 'prepare_apk_package_transition','replace_sing_box_package_variant','pkg_install_rollback_files',
 'restore_sing_box_package_variant','run_logged_pkg_remove_sing_box_conflict','pkg_remove_sing_box_conflict'];
function fixture(sourceName='sing-box-extended'){
 const sourceVersion=sourceName==='sing-box-extended'?'1.14.3.2.7.3-r0':'1.13.0-r0';
 const packages=[{name:sourceName,version:sourceVersion},
  {name:'ca-bundle',version:'20260601-r1'},{name:'kernel',version:'6.12.44~abc123-r1'},
  {name:'libc',version:'1.2.5-r0'},{name:'busybox',version:'1.37.0-r5'}];
 const originalWorld='busybox\nlibc@base~1.2\n'+sourceName+'><Q1original\n!excluded\n';
 const state={packages:structuredClone(packages),world:originalWorld,originalWorld,commands:[],writes:{},present:true,
  repositories:'[]',overridePlan:null,failInstall:false,failWrite:false,tampered:false,snapshot:null,filesRestored:false};
 const archive={'/tmp/old.apk':{name:sourceName,version:sourceVersion},
  '/tmp/extended.apk':{name:'sing-box-extended',version:'2.0.0.1.0-r0'},
  '/tmp/stable.apk':{name:'sing-box',version:'1.14.2-r1'},'/tmp/tiny.apk':{name:'sing-box-tiny',version:'1.14.2-r1'}};
 let argv;
 function plan(a){
  if(state.overridePlan!==null)return state.overridePlan;
  const target=archive[a.find(x=>x.endsWith('.apk'))],ops=[];
  for(const item of state.packages)if(a.includes('!'+item.name)||(target&&target.name!=='sing-box'&&item.name==='sing-box'))ops.push('Purging '+item.name+' ('+item.version+')');
  if(target){const old=state.packages.find(p=>p.name===target.name);
   if(!old)ops.push('Installing '+target.name+' ('+target.version+')');
   else if(old.version!==target.version)ops.push('Upgrading '+target.name+' ('+old.version+' -> '+target.version+')');
   else if(a.includes('--force-reinstall'))ops.push('Reinstalling '+target.name+' ('+target.version+')');
  }
  return ops.map((op,i)=>`(${i+1}/${ops.length}) ${op}\n`).join('')+'OK: 136.6 MiB in 239 packages\n';
 }
 const c={...primitive,rollback_package:{name:sourceName,version:sourceVersion,path:'/tmp/old.apk',digest:'oldhash'},
  rollback_package_files:['/tmp/old.apk'],rollback_packages:[],isolated_extended_apk_update:false,tmp_dir:'/tmp',
  command_from_args:a=>{argv=Array.from(a);return JSON.stringify(argv)},
  command_output_from_args:a=>a.includes('repositories')?state.repositories:JSON.stringify(state.snapshot||state.packages),
  command_output:command=>plan(JSON.parse(command.slice(0,command.indexOf(' </dev/null')))),
  installed_package_version:name=>(state.packages.find(p=>p.name===name)||{}).version||'',
  fs:{readfile:()=>state.world,rename:(file)=>{if(state.failWrite)return false;state.world=state.writes[file];return true}},
  write_file:(file,text)=>{state.writes[file]=text;return !state.failWrite},owner_pid:()=>100,remove_file:()=>{},
  rollback_files_valid:()=>state.present,rollback_archive_digest:file=>state.tampered?'tampered':file==='/tmp/old.apk'?'oldhash':'newhash',
  run_logged_install:(_label,command)=>{
   const a=JSON.parse(command.slice(0,command.indexOf(' </dev/null')));state.commands.push(a);
   assert(a.includes('--no-network'));assert(a.includes('--repositories-file'));assert(a.includes('/dev/null'));
   assert(!a.includes('--force-broken-world'));assert(!a.includes('del'));
   if(a.includes('--force-reinstall'))assert(!a.some(x=>/^(ca-bundle|kernel|libc|busybox)=/.test(x)),
    'force-reinstall must never name pinned dependencies');
   if(state.failInstall){state.world='partial pins\n';return false;}
   const target=archive[a.find(x=>x.endsWith('.apk'))];
   state.packages=state.packages.filter(p=>!a.includes('!'+p.name)&&!(target&&target.name!=='sing-box'&&p.name==='sing-box'));
   if(target){state.packages=state.packages.filter(p=>p.name!==target.name);state.packages.push({...target});state.filesRestored=true;}
   state.world=a.filter(x=>x.includes('=')||x.startsWith('!')).join('\n')+'\n';
   return true;
  },pkg_is_installed:name=>state.packages.some(p=>p.name===name),is_apk:()=>true,
  prepare_sing_box_package_service_install:()=>{},file_nonempty:()=>true,
  sing_box_variant_is_package_managed:v=>['extended','tiny','stable'].includes(v),
 };
 vm.createContext(c);vm.runInContext(functions.map(body).join('\n'),c);
 return {c,state,packages,archive,argv:()=>argv};
}
{
 const {c}=fixture();
 const ok='OK: 136.6 MiB in 239 packages\n';
 assert(c.apk_transition_plan_safe('(1/2) Purging sing-box-extended (old)\n(2/2) Installing sing-box (new)\n'+ok,'sing-box',false));
 assert(c.apk_transition_plan_safe('(1/1) Purging sing-box-extended (old)\n'+ok,'',false));
 assert(c.apk_transition_plan_safe(ok,'sing-box-extended',true));
 assert(!c.apk_transition_plan_safe(ok,'sing-box-extended',false));
 for(const bad of ['','unexpected output',ok+ok,
  '(1/2) Purging ca-bundle (20260601-r1)\n(2/2) Installing sing-box (new)\n'+ok,
  '(1/2) Upgrading libc (old -> new)\n(2/2) Installing sing-box (new)\n'+ok,
  '(1/1) Installing sing-box-tiny (new)\n'+ok,
  '(2/2) Installing sing-box (new)\n'+ok,
  '(1/2) Installing sing-box (new)\n'+ok,
  ok+'(1/1) Installing sing-box (new)\n',
  '(1/2) Purging sing-box (old)\n(2/2) Installing sing-box (new)\n'+ok])
  assert(!c.apk_transition_plan_safe(bad,'sing-box',false),bad);
}
for(const [target,file] of [['sing-box','/tmp/stable.apk'],['sing-box-tiny','/tmp/tiny.apk'],['','']]){
 const {c,state,packages}=fixture();
 const transition=c.prepare_apk_package_transition('sing-box-extended',target,file,target?'1.14.2-r1':'');
 assert(transition,'old unavailable ca-bundle must not block an installed-only compatible transition');
 assert.equal(transition.packages.length,4);assert.equal(state.commands.length,0,'preflight is read-only');
 c.rollback_package.apk_transition=transition;
 if(target)assert(c.replace_sing_box_package_variant(target,target==='sing-box'?'sing-box-tiny':'sing-box','1.14.2-r1'));
 else assert(c.run_logged_pkg_remove_sing_box_conflict('sing-box-extended','remove Extended package'));
 assert.equal(state.commands.length,1);
 assert(state.commands[0].includes('ca-bundle=20260601-r1'));
 assert(state.commands[0].includes('kernel=6.12.44~abc123-r1'));
 assert(!state.commands[0].includes('--force-reinstall'));
 assert.equal(state.world,'busybox\nlibc@base~1.2\n!excluded\n'+(target?target+'\n':''));
 for(const item of packages.filter(x=>x.name!=='sing-box-extended'))assert.equal(c.installed_package_version(item.name),item.version);
 assert(c.restore_sing_box_package_variant('extended'),'exact offline package rollback succeeds');
 assert.equal(c.installed_package_version('sing-box-extended'),'1.14.3.2.7.3-r0');
 assert.equal(c.installed_package_version('sing-box'),'');assert.equal(c.installed_package_version('sing-box-tiny'),'');
 assert.equal(state.world,state.originalWorld,'rollback restores the exact original world including pin/tag/conflict');
 assert(state.filesRestored);
 assert.equal(state.commands.length,2,'variant rollback restores old core without standalone dependency deletion');
}
{
 const {c,state}=fixture();const t=c.prepare_apk_package_transition('sing-box-extended','sing-box','/tmp/stable.apk','1.14.2-r1');
 c.rollback_package.apk_transition=t;state.filesRestored=false;
 assert(c.restore_sing_box_package_variant('extended'),'failure before old removal still reinstalls missing old payload');
 assert.equal(state.commands.length,2);assert(state.commands[1].includes('--force-reinstall'));
 assert.deepEqual(state.commands[1].slice(-2),['--force-reinstall','/tmp/old.apk']);
 assert(state.filesRestored);assert.equal(state.world,state.originalWorld);
}
for(const failure of ['repositories','unknown-repositories','dependency-plan','install-plan','archive','dependency-drift','write','install','missing-rollback']){
 const {c,state}=fixture();const t=c.prepare_apk_package_transition('sing-box-extended','sing-box','/tmp/stable.apk','1.14.2-r1');
 c.rollback_package.apk_transition=t;
 if(failure==='repositories')state.repositories='[{"name":"unwanted"}]';
 if(failure==='unknown-repositories')state.repositories='not-json';
 if(failure==='dependency-plan')state.overridePlan='(1/2) Purging ca-bundle (old)\n(2/2) Installing sing-box (new)\nOK: 1 MiB in 2 packages\n';
 if(failure==='install-plan')state.overridePlan='(1/2) Installing new-dependency (new)\n(2/2) Installing sing-box (new)\nOK: 1 MiB in 2 packages\n';
 if(failure==='archive')state.tampered=true;
 if(failure==='dependency-drift')state.packages.find(x=>x.name==='ca-bundle').version='changed';
 if(failure==='write')state.failWrite=true;
 if(failure==='install')state.failInstall=true;
 if(failure==='missing-rollback')state.present=false;
 assert(!c.replace_sing_box_package_variant('sing-box','sing-box-tiny','1.14.2-r1'),failure+' must fail closed');
 if(!['write','install'].includes(failure))assert.equal(state.commands.length,0,failure+' aborts before mutation');
 if(failure==='install')assert.equal(state.world,state.originalWorld,'failed add must remove any temporary world pins');
}
for(const failure of ['malformed','duplicate','missing-core','ambiguous-core','unreadable-world','bad-version','installed-mismatch']){
 const {c,state}=fixture();
 if(failure==='malformed')state.snapshot={};
 if(failure==='duplicate')state.snapshot=[...state.packages,state.packages[0]];
 if(failure==='missing-core')state.snapshot=state.packages.slice(1);
 if(failure==='ambiguous-core'){state.packages.push({name:'sing-box',version:'1'});}
 if(failure==='unreadable-world')state.world=null;
 if(failure==='bad-version')state.packages[1].version='20260601 r1';
 if(failure==='installed-mismatch')state.snapshot=state.packages.map(x=>({...x,version:'other'}));
 assert.equal(c.prepare_apk_package_transition('sing-box-extended','sing-box','/tmp/stable.apk','1.14.2-r1'),null,failure);
 assert.equal(state.commands.length,0);
}
console.log('issue96 core-only APK transitions, strict plans, dependency pins, exact rollback/world and failure checks passed');

for(const sourceName of ['sing-box','sing-box-tiny','sing-box-extended'])
 for(const [target,file] of [['sing-box','/tmp/stable.apk'],['sing-box-tiny','/tmp/tiny.apk'],['sing-box-extended','/tmp/extended.apk'],['','']]){
  const {c,state,archive}=fixture(sourceName),version=target?archive[file].version:'';
  const t=c.prepare_apk_package_transition(sourceName,target,file,version);assert(t,sourceName+' -> '+target);
  assert.equal(t.source_name,sourceName);c.rollback_package.apk_transition=t;
  assert(c.apply_apk_core_transition(t,target,file,version));
  assert.equal(c.installed_package_version(sourceName),target===sourceName?version:'');
  assert.equal(c.installed_package_version('ca-bundle'),'20260601-r1');
  const sourceVariant=sourceName==='sing-box'?'stable':sourceName==='sing-box-tiny'?'tiny':'extended';
  assert(c.restore_sing_box_package_variant(sourceVariant),sourceName+' <- '+target);
  assert.equal(c.installed_package_version(sourceName),archive['/tmp/old.apk'].version);
  for(const other of ['sing-box','sing-box-tiny','sing-box-extended'].filter(x=>x!==sourceName))assert.equal(c.installed_package_version(other),'');
  assert.equal(state.world,state.originalWorld);
 }
console.log('issue96 complete known package-source/target matrix passed');
