// SPDX-License-Identifier: Apache-2.0
let state=require("warp.state"),transport=require("warp.transport"),stability=require("warp.stability"),job=require("warp.job");
const PATH=state.RUNTIME+"/watchdog.json";
function decide(previous,status,healthy,now) {
    let value={attempts:previous.attempts||0,failures:previous.failures||0,next_retry_at:previous.next_retry_at||0,exhausted:previous.exhausted===true,reconnect:false};
    if(status.enabled!==true || healthy)return {attempts:0,failures:0,next_retry_at:0,exhausted:false,reconnect:false};
    value.failures++;
    if(value.attempts>=3){value.exhausted=true;return value;}
    if(value.failures<3 || now<value.next_retry_at)return value;
    value.attempts++;value.reconnect=true;value.next_retry_at=now+[60,120,300][value.attempts-1];return value;
}
function public_status() {
    let value=state.load(PATH)||{},result={exhausted:value.exhausted===true};
    for(let key in ["attempts","failures","next_retry_at"])if(type(value[key])=="int" && value[key]>=0)result[key]=value[key];
    return result;
}
function tick() {
    let active=job.status();if(active.running || active.recovery_pending)return {reconnect:false};
    let current=transport.status(),check=current.enabled && current.running?stability.health(current.interface,"watchdog"):null;
    let healthy=check && check.success && check.warp;
    let value=decide(state.load(PATH)||{},current,healthy,clock()[0]);
    if(!state.save(PATH,value))return {reconnect:false};
    return value;
}
function reset(){return state.remove(PATH);}
return {decide,tick,reset,public_status};
