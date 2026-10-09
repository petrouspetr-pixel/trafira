// Pure policy: an API/probe error is not evidence of an unavailable tunnel.
function min(a,b){return a<b?a:b;}
function max(a,b){return a>b?a:b;}
function valid(policy) {
    if(type(policy)!="object" || index(["legacy","block","reserve","direct"],policy.mode)<0)return false;
    if(policy.mode=="legacy")return true;
    return type(policy.failures)=="int" && policy.failures>=1 && policy.failures<=10 &&
        type(policy.recoveries)=="int" && policy.recoveries>=1 && policy.recoveries<=10 &&
        type(policy.hold_seconds)=="int" && policy.hold_seconds>=30 && policy.hold_seconds<=600 &&
        (policy.mode!="reserve" || (type(policy.reserve_section)=="string" && match(policy.reserve_section,/^[A-Za-z0-9_]{1,64}$/)));
}
function option_number(section,key,fallback) {
    let value=section[key];
    if(value==null || value=="")return fallback;
    return match(""+value,/^[0-9]+$/)?int(value,10):-1;
}
function from_section(section) {
    return {mode:section.failure_policy||"legacy",reserve_section:section.failure_reserve_section||"",
        failures:option_number(section,"failure_threshold",3),recoveries:option_number(section,"recovery_threshold",2),
        hold_seconds:option_number(section,"failure_hold_seconds",30)};
}
function initial(now) {
    return {mode:"blocked",fail_count:0,success_count:0,last_transition:0,observed_at:now,initialized:false,monitor_error:false};
}
function step(previous,sample,now,policy) {
    if(!valid(policy))return {state:initial(now),transition:null,error:"invalid_policy"};
    if(policy.mode=="legacy")return {state:previous||{mode:"legacy"},transition:null};
    let state=type(previous)=="object"?{...previous}:initial(now);
    if(index(["primary","reserve","direct","blocked"],state.mode)<0 || now<state.observed_at || now-state.observed_at>max(60,policy.hold_seconds*2))state=initial(now);
    let from=state.mode;
    state.observed_at=now;
    let primary=sample?sample.primary:"unknown",reserve=sample?sample.reserve:"unknown";
    state.monitor_error=primary!="up" && primary!="down";
    state.fail_count=primary=="down"?min(policy.failures,int(state.fail_count||0)+1):0;
    state.success_count=primary=="up"?min(policy.recoveries,int(state.success_count||0)+1):0;
    let target=from,reason="";
    // A selected reserve that is no longer known healthy is never replaced by
    // direct, and blocking must not wait for the anti-flapping interval.
    if(from=="reserve" && reserve!="up") {target="blocked";reason="reserve_unavailable";state.monitor_error=reserve!="down";}
    let held=state.initialized!==false && now-state.last_transition<policy.hold_seconds;
    if(!held && state.success_count>=policy.recoveries) {target="primary";reason="primary_recovered";}
    else if(!held && state.fail_count>=policy.failures) {
        target=policy.mode=="direct"?"direct":policy.mode=="reserve" && reserve=="up"?"reserve":"blocked";
        reason=target=="reserve"?"reserve_selected":target=="direct"?"direct_selected":"primary_unavailable";
    }
    let transition=null;
    if(target!=from) {
        state.mode=target;state.last_transition=now;state.initialized=true;state.reason=reason;
        state.fail_count=0;state.success_count=0;
        transition={from,to:target,reason};
    }
    return {state,transition};
}
function enabled(section){return section.enabled==null || index(["0","false","off","no"],""+section.enabled)<0;}
function connection(section){return index(["connection","proxy","outbound","vpn"],section.action)>=0;}
function validate_sections(sections) {
    let by_name={},edges={},errors=[];
    for(let section in sections||[])by_name[section[".name"]]=section;
    for(let section in sections||[]) {
        let name=section[".name"],policy=from_section(section);edges[name]=[];
        if(!enabled(section))continue;
        if(!valid(policy))push(errors,name+": invalid failure policy");
        if(policy.mode!="legacy" && !connection(section))push(errors,name+": failure policy requires a Connection section");
        if(policy.mode=="reserve") {
            let target=by_name[policy.reserve_section];
            if(!target || !enabled(target) || !connection(target))push(errors,name+": reserve must be an enabled Connection section");
            else push(edges[name],policy.reserve_section);
        }
        if(index(["1","true","yes","on"],""+section.outbound_detour_enabled)>=0 && section.outbound_detour_section)
            push(edges[name],section.outbound_detour_section);
    }
    // Iterative reachability has a finite section budget and includes detours.
    for(let name in edges) {
        let queue=[...(edges[name]||[])],visited={};
        for(let i=0;i<length(queue);i++) {
            let target=queue[i];
            if(target==name) {push(errors,name+": reserve/detour dependency cycle");break;}
            if(visited[target])continue;
            visited[target]=true;
            for(let next in edges[target]||[])if(!visited[next])push(queue,next);
        }
    }
    return errors;
}
return {valid,from_section,step,validate_sections,initial};
