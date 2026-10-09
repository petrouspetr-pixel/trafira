// A failed or interrupted transition keeps its kernel guard. It is released
// only after a verified configuration, or an explicit Trafira stop/restart.
function transition(expected,hooks) {
    let guarded=false,stage="prepare";
    try {
        if(hooks.generation()!=expected)return {success:false,error:"conflict"};
        if(!hooks.prepare())return {success:false,error:"candidate_check_failed"};
        if(hooks.generation()!=expected)return {success:false,error:"conflict"};
        stage="guard";
        if(!hooks.guard())return {success:false,error:"guard_failed"};
        guarded=true;
        for(let next in ["install","reload","healthy","publish","unguard"]) {
            stage=next;
            if(!hooks[next]()) {
                let restored=hooks.restore();
                return {success:false,error:next+"_failed",guarded:true,restored};
            }
        }
        return {success:true,guarded:false};
    }catch(e) {
        let restored=false;
        if(guarded)try {restored=hooks.restore();}catch(ignored){}
        return {success:false,error:stage+"_failed",guarded,restored};
    }
}
function guard_script(ports,mark) {
    mark=mark||"0x04000000";
    if(!match(mark,/^0x[0-9a-fA-F]{1,8}$/))return null;
    let safe=[];
    for(let port in ports||[]) {
        if(type(port)!="int" || port<1 || port>65535)return null;
        if(index(safe,port)<0)push(safe,port);
    }
    let text="add table inet TrafiraFailureGuard\nflush table inet TrafiraFailureGuard\n"+
        "add chain inet TrafiraFailureGuard capture { type filter hook prerouting priority -149; policy accept; }\n"+
        "add rule inet TrafiraFailureGuard capture meta mark & "+mark+" != 0 counter drop\n"+
        "add chain inet TrafiraFailureGuard local { type filter hook input priority -151; policy accept; }\n";
    if(length(safe))text+="add rule inet TrafiraFailureGuard local meta l4proto { tcp, udp } th dport { "+join(", ",safe)+" } counter drop\n";
    // The legacy DNS listener receives forwarded dnsmasq requests on loopback.
    text+="add rule inet TrafiraFailureGuard local ip daddr 127.0.0.42 meta l4proto { tcp, udp } th dport 53 counter drop\n";
    return text;
}
return {transition,guard_script};
