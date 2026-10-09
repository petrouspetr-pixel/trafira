// SPDX-License-Identifier: Apache-2.0
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=()=>fs.readFileSync(path.join(__dirname,'../../components/warp/luci-app-trafira-warp/htdocs/luci-static/resources/view/trafira-warp/main.js'),'utf8');
function harness(){
 const calls=[],timers=new Set(),events={},notifications=[];
 const window={addEventListener(name,fn){events[name]=fn;},removeEventListener(name){delete events[name];}};
 const poll={add(fn){timers.add(fn);},remove(fn){timers.delete(fn);}};
 const rpc={declare(spec){return (...args)=>{calls.push({method:spec.method,args});return Promise.resolve({success:true,job:{running:true,job_id:'w-fixture'},running:true,registered:true});};}};
 function E(tag,attrs,children){assert.notEqual(typeof children,"string","LuCI string children use HTML; wrap text in array");return {tag,attrs:attrs||{},children:children||[],replaceChildren(...v){this.children=v;},appendChild(v){this.children.push(v);}};}
 const context={window,view:{extend:x=>x},rpc,poll,ui:{showModal(){},hideModal(){},addNotification(...args){notifications.push(args);}},E,_:x=>x,Promise,JSON,String,Array,Object};
 const page=vm.runInNewContext('(function(){'+source()+'})()',context);
 return {page,calls,timers,events,notifications};
}
test('load recovers active job; leaving only stops polling',async()=>{
 const h=harness();let data=await h.page.load();h.page.render(data);
 assert.equal(h.page.state.job.job_id,'w-fixture');assert.equal(h.timers.size,1);
 assert.equal(typeof h.events.pagehide,"function");h.events.pagehide();assert.equal(h.timers.size,0);assert.equal(h.calls.filter(c=>c.method==='action').length,0);
});
test('apply requires preview and does not allow concurrent mutations',async()=>{
 const h=harness();h.page.state={job:{running:false}};
 await h.page.applyPreview();assert.equal(h.calls.length,0);
 h.page.state.job.running=true;
 await h.page.act({action:'disable'});assert.equal(h.calls.length,0);
});
test('stale preview discarded after failure; errors rendered as text',async()=>{
 const h=harness();h.page.state={job:{running:false}};h.page.preview={preview_id:'p-fixture',expected_digest:'a'.repeat(64),removal:false};
 h.page.callAction=async()=>({success:false,error:'<img src=x onerror=alert(1)>'});
 await h.page.applyPreview();assert.equal(h.page.preview,null);
 assert.doesNotMatch(source(),/innerHTML|insertAdjacentHTML/);
});

test('RPC errors are visible and timing seconds are displayed as milliseconds',async()=>{
 const h=harness();h.page.render({success:true,running:true,registered:true,job:{running:false},test:{summary:{samples:2,median:0.2,p95:0.3}}});
 assert.match(JSON.stringify(h.page.panel),/200 \/ 300/);
 h.page.callAction=async()=>{throw Error('offline');};
 await h.page.act({action:'reconnect'});assert.equal(h.notifications.length,1);
 assert.equal(h.page.pending,false);
});
