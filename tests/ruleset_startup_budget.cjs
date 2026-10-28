'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../trafira/files/usr/lib/singbox/ruleset_bootstrap.uc'), 'utf8');
function scenario(settings = {}, duration = 1, testBudget) {
  let elapsed = 0, valid = false;
  const requests = [], warnings = [];
  const rule = {type:'remote',tag:'required',format:'source',url:'https://example.invalid/list',http_client:{detour:'warp'}};
  const cache = {path:()=>'/cache/required',validate:()=>valid,save:()=>{valid=true; return true;},protect:()=>valid};
  const uci = {get:key=>settings[key.split('.').pop()],get_all:()=>settings};
  const context = {require:name=>({'fs':{popen:()=>({read:()=>'/tmp/trafira-ruleset-bootstrap.XXXXXX',close:()=>0}),lstat:()=>({type:'file',size:64000}),unlink:()=>true,mkdir:()=>true},'core.common':{array_or_empty:v=>Array.isArray(v)?v:[],object_or_empty:v=>v||{}},'singbox.ruleset_cache':cache,'core.uci':uci,'service.operation_lock':{identity:()=>({pid:1,ticks:1})}}[name]),
    harnessFetch:(config, rule, candidate, directory, seconds)=>{requests.push({candidate,seconds});elapsed+=Math.min(duration,seconds);return duration<=seconds;},
    getenv:key=>key==='TRAFIRA_BOOTSTRAP_TEST_BUDGET'?testBudget:undefined,
    min:Math.min,max:Math.max,int:v=>parseInt(v,10),match:(v,r)=>String(v).match(r),type:v=>v===null?'null':Array.isArray(v)?'array':typeof v,
    filter:(a,f)=>a.filter(f),map:(a,f)=>a.map(f),push:(a,v)=>a.push(v),index:(a,v)=>a.indexOf(v),length:v=>v.length,
    clock:()=>[elapsed],system:()=>0,join:(s,a)=>a.join(s),replace:(s,r,v)=>s.replace(r,v),trim:s=>s.trim(),warn:(...v)=>warnings.push(v.join('')),ARGV:[]};
  const code=source.replace(/for\s*\(\s*let\s+(\w+)\s+in\s+/g,'for (let $1 of ').replace(/return\s*\{\s*plan\s*,\s*stage\s*,\s*prepare\s*,\s*prepare_file\s*\}\s*;/,'fetch = harnessFetch; return {plan, stage, prepare, prepare_file};');
  const bootstrap=vm.runInNewContext('(function(){'+code+'})()',context);
  const config={outbounds:[{tag:'warp',type:'wireguard'}],route:{rule_set:[rule]}};
  const ok=bootstrap.prepare(config,'1.14.3');
  return {ok,requests,warnings,elapsed,valid};
}
// A 64KB list takes over ten seconds at 50 kbit/s. The configured request
// timeout must reach the production fetch call, while the overall cap wins.
assert.equal(scenario({},11).ok,false,'default request cap remains ten seconds');
let slow=scenario({ruleset_startup_timeout:'600',ruleset_download_timeout:'120'},11);
assert.equal(slow.ok,true,'configured slow-link download must survive the old ten-second cap');
assert.equal(slow.requests[0].seconds,120);
let capped=scenario({ruleset_startup_timeout:'20',ruleset_download_timeout:'120'},21);
assert.equal(capped.ok,false,'overall deadline bounds each request');
assert.equal(capped.requests[0].seconds,20);
let testing=scenario({ruleset_startup_timeout:'600',ruleset_download_timeout:'120'},3,'2');
assert.equal(testing.ok,false,'test cap remains bounded by production supervision');
assert.equal(testing.requests[0].seconds,2);
for(const [key,value] of [['ruleset_startup_timeout','0'],['ruleset_startup_timeout','1801'],['ruleset_download_timeout','2'],['ruleset_download_timeout','120s'],['ruleset_download_timeout','NaN']]) {
  let invalid=scenario({[key]:value});
  assert.equal(invalid.ok,false,'invalid '+key+' must fail closed');
  assert.equal(invalid.requests.length,0,'invalid budget must not download');
  assert(invalid.warnings.join('').includes(key),'error names '+key);
}
console.log('Rule-set startup configurable deadline checks passed');
