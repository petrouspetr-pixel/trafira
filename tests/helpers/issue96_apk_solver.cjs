// Execute the production command/plan/world helpers; never reconstruct shell commands.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const [sourcePath,mode,transitionFile,name,file,simulate,reinstall,planFile,required]=process.argv.slice(2);
const source=fs.readFileSync(sourcePath,'utf8');
function body(name){let a=source.indexOf('function '+name+'(');assert(a>=0,name);let b=source.indexOf('\nfunction ',a+1);return source.slice(a,b).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
let argv;
const c={push:(a,v)=>a.push(v),split:(s,sep)=>s.split(sep),trim:s=>s.trim(),match:(s,r)=>s.match(r),int:Number,
 join:(sep,a)=>a.join(sep),command_from_args:a=>{argv=Array.from(a);return ""}};
vm.createContext(c);vm.runInContext(['apk_transition_command','apk_transition_plan_safe','apk_transition_world'].map(body).join('\n'),c);
if(mode==='lookup'){
 const cp=require('node:child_process'),path=require('node:path');
 const packageSource=fs.readFileSync(path.resolve(path.dirname(sourcePath),'../core/packages.uc'),'utf8');
 function packageBody(name){const a=packageSource.indexOf('function '+name+'(');assert(a>=0,name);return packageSource.slice(a,packageSource.indexOf('\nfunction ',a+1)).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
 const run=args=>cp.spawnSync(process.env.APK_BIN,['--root',file,'--no-network','--repositories-file','/dev/null',...args.slice(1)],{encoding:'utf8'});
 const lookup={...c,as_string:x=>x==null?'':String(x),length:x=>x.length,substr:(s,a,b)=>s.substr(a,b),
  type:x=>Array.isArray(x)?'array':typeof x,json:JSON.parse,command_exists:()=>true,
  command_output:args=>{const result=run(args);return result.status===0?result.stdout:''},command_success:args=>run(args).status===0,
  is_apk:()=>true,LIB_DIR:'/test'};
 vm.createContext(lookup);vm.runInContext(['apk_installed','apk_manifest_version','apk_info_version','apk_list_version','apk_query_version','apk_version'].map(packageBody).join('\n'),lookup);
 lookup.pkg_is_installed=p=>lookup.apk_installed(p);lookup.module_output=args=>lookup.apk_version(args[args.length-1]);
 vm.runInContext(body('installed_package_version'),lookup);
 for(const core of ['sing-box','sing-box-tiny','sing-box-extended'])assert.equal(lookup.installed_package_version(core),core===name?simulate:'','production installed lookup must distinguish concrete package '+core);
 for(const [pkg,version] of [['ca-bundle','20260601-r1'],['kernel','6.12.44-r1']])assert.equal(lookup.installed_package_version(pkg),version);
 process.exit(0);
}
const transition=JSON.parse(fs.readFileSync(transitionFile,'utf8'));
if(mode==='command'){c.apk_transition_command(transition,name,file,simulate==='1',reinstall==='1');for(const arg of argv.slice(1))process.stdout.write(arg+'\0');}
else if(mode==='plan')assert(c.apk_transition_plan_safe(fs.readFileSync(planFile,'utf8'),name,simulate==='1',JSON.parse(required||'[]')),'production plan validator rejected actual APK solver output');
else if(mode==='world')process.stdout.write(c.apk_transition_world(transition,name));
else throw Error('unsupported mode');
