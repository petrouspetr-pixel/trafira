const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const path=require('node:path'),root=path.resolve(__dirname,'..');
const source=fs.readFileSync(path.join(root,'trafira/files/usr/lib/core/packages.uc'),'utf8');
function body(name){const a=source.indexOf('function '+name+'(');assert(a>=0,name);return source.slice(a,source.indexOf('\nfunction ',a+1)).replace(/for \(let (\w+) in /g,'for (let $1 of ');}
const c={as_string:x=>x==null?'':String(x),type:x=>Array.isArray(x)?'array':typeof x,json:JSON.parse,
 split:(s,r)=>s.split(r),trim:s=>s.trim(),substr:(s,a,b)=>s.substr(a,b),length:s=>s.length,
 match:(s,r)=>s.match(r),command_exists:()=>true,apk_installed:()=>true};
let query='[]',calls=[];
c.command_output=args=>{calls.push(args);if(args[0]==='apk'&&args[1]==='query')return query;
 if(args.includes('--manifest'))return 'P:sing-box-extended\nV:1.14.3.2.7.3-r0\n';
 return 'sing-box-extended-1.14.3.2.7.3-r0 x86_64 [installed]\n';};
vm.createContext(c);vm.runInContext(['apk_manifest_version','apk_info_version','apk_list_version','apk_query_version','apk_version'].map(body).join('\n'),c);
assert.equal(c.apk_version('sing-box'),'','an authoritative empty query cannot turn a virtual provider into concrete Stable');
assert.equal(calls.length,1,'authoritative empty result must not fall back');
query='[{"name":"sing-box-extended","version":"1.14.3.2.7.3-r0"}]';calls=[];
assert.equal(c.apk_version('sing-box'),'','provider-only JSON means no concrete package');assert.equal(calls.length,1);
query='[{"name":"sing-box-extended","version":"1"},{"name":"sing-box","version":"1.14.2-r1"}]';
assert.equal(c.apk_version('sing-box'),'1.14.2-r1');
query='not-json';assert.equal(c.apk_version('sing-box'),'','malformed successful query fails closed');
query='';assert.equal(c.apk_version('sing-box'),'','legacy fallback rejects longer package-name prefix');
assert.equal(c.apk_list_version('sing-box','sing-box-extended-1-r0 x86_64 [installed]'),'');
assert.equal(c.apk_info_version('sing-box','sing-box-extended-1-r0'),'');
assert.equal(c.apk_list_version('zapret','<zapret> zapret-72.20260307-r1 aarch64 [installed]'),'72.20260307-r1');
console.log('issue96 authoritative concrete APK version and legacy prefix rejection passed');
