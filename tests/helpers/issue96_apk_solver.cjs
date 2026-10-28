// Execute the production command/plan/world helpers; never reconstruct shell commands.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const [sourcePath,mode,transitionFile,name,file,simulate,reinstall,planFile,required]=process.argv.slice(2);
const source=fs.readFileSync(sourcePath,'utf8');
function body(name){let a=source.indexOf('function '+name+'(');assert(a>=0,name);let b=source.indexOf('\nfunction ',a+1);return source.slice(a,b).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
let argv;
const c={push:(a,v)=>a.push(v),split:(s,sep)=>s.split(sep),trim:s=>s.trim(),match:(s,r)=>s.match(r),int:Number,
 join:(sep,a)=>a.join(sep),command_from_args:a=>{argv=Array.from(a);return ""}};
vm.createContext(c);vm.runInContext(['apk_transition_command','apk_transition_plan_safe','apk_transition_world'].map(body).join('\n'),c);
const transition=JSON.parse(fs.readFileSync(transitionFile,'utf8'));
if(mode==='command'){c.apk_transition_command(transition,name,file,simulate==='1',reinstall==='1');for(const arg of argv.slice(1))process.stdout.write(arg+'\0');}
else if(mode==='plan')assert(c.apk_transition_plan_safe(fs.readFileSync(planFile,'utf8'),name,simulate==='1',JSON.parse(required||'[]')),'production plan validator rejected actual APK solver output');
else if(mode==='world')process.stdout.write(c.apk_transition_world(transition,name));
else throw Error('unsupported mode');
