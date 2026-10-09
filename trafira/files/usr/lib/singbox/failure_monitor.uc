let policy=require("singbox.failure_policy");
function sample(response,proxies,tag) {
    if(type(proxies)!="object")return {health:"unknown",selected:""};
    let current=tag,seen={};
    for(let depth=0;depth<32;depth++) {
        if(!proxies[current])return {health:"down",selected:current};
        if(seen[current])return {health:"unknown",selected:""};
        seen[current]=true;
        let next=proxies[current].now;
        if(!next)break;
        current=next;
    }
    if(proxies[current] && proxies[current].now)return {health:"unknown",selected:""};
    if(type(response)=="object" && type(response.delay)=="int" && response.delay>=0)return {health:"up",selected:current};
    let message=type(response)=="object"?response.message:"";
    if(type(message)=="string" && match(lc(message),/(timeout|timed out|connection refused|network is unreachable|no route to host)/))
        return {health:"down",selected:current};
    return {health:"unknown",selected:current};
}
function observe(section,previous,primary,reserve,now) {
    let from=previous?previous.mode:"blocked",state=previous;
    if(previous && primary.selected && previous.selected && primary.selected!=previous.selected)state=policy.initial(now);
    let result=policy.step(state,{primary:primary.health,reserve:reserve.health},now,policy.from_section(section));
    result.state.selected=primary.selected||(previous?previous.selected:"")||"";
    result.changed=result.state.mode!=from;
    return result;
}
return {sample,observe};
