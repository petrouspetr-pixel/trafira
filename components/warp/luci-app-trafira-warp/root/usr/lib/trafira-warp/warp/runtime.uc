// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),job=require("warp.job"),transport=require("warp.transport"),scout=require("warp.scout"),stability=require("warp.stability");
function status() {
    let current=transport.status(),account=state.load(state.DIRECTORY+"/account.json"),test=state.load(state.RUNTIME+"/test.json"),candidate=state.load(state.RUNTIME+"/candidate.json");
    let result={...current,registered:scout.account_valid(account),job:job.status()};
    if(test) {
        result.test={...state.public_status(test),summary:{}};
        for(let key in ["samples","transport_errors","http_restricted","median","p95"])
            if(index(["int","double"],type((test.summary||{})[key]))>=0)result.test.summary[key]=test.summary[key];
    }
    if(candidate && scout.candidate_current(candidate,scout.digest(),current.generation||0,clock()[0]) && transport.valid_config(candidate.config))
        result.candidate={candidate_id:candidate.candidate_id,endpoint:candidate.config.endpoint,expires_at:candidate.expires_at};
    return result;
}
function activate(config,id) {
    let result=transport.apply(config,id);if(!result.success || !config.enabled)return result;
    let healthy=stability.health(config.interface,id);
    if(!healthy.success || !healthy.warp)return {success:false,error:"https_probe_failed"};
    let runtime=state.load(state.RUNTIME+"/transport.json");
    if(!runtime || !state.save(state.RUNTIME+"/transport.json",{...runtime,https_ok:true,warp:true,checked_at:clock()[0]}))return {success:false,error:"storage_unavailable"};
    return {success:true};
}
function refresh_health(id) {
    let live=transport.status();if(!live.running)return {success:false,error:"transport_stopped"};
    let check=stability.health(live.interface,id),current=state.load(state.RUNTIME+"/transport.json");
    if(!current || current.generation!=live.generation)return {success:false,error:"transport_changed"};
    if(!state.save(state.RUNTIME+"/transport.json",{...current,https_ok:check.success===true,warp:check.warp===true,checked_at:clock()[0]}))return {success:false,error:"storage_unavailable"};
    return status();
}
function hooks(integration) {
    integration=integration||{};
    function snapshot() {
        return {transport:transport.snapshot(),account:state.load(state.DIRECTORY+"/account.json"),integration:integration.capture?integration.capture():null};
    }
    function restore(saved) {
        let current=state.load(state.DIRECTORY+"/transport.json"),old=saved.transport;
        let same=sprintf("%J",current)==sprintf("%J",old.config) && transport.status().running===old.running;
        let ok=same || transport.restore(old,"recovery");
        // Keep an account already created at Cloudflare when discovery is cancelled.
        // Erasing the only credential copy cannot undo that remote registration.
        if(saved.account)ok=state.save(state.DIRECTORY+"/account.json",saved.account) && ok;
        if(integration.restore)ok=integration.restore(saved.integration) && ok;
        return ok;
    }
    function perform(request,id) {
        let mark=integration.mark||134217728;
        if(mark!=134217728)return {success:false,error:"mark_conflict"};
        if(request.action=="status")return {success:true};
        if(request.action=="test_start")return stability.run(request.duration,request.services,id);
        if(request.action=="scan_start")return scout.run(request.mode,mark,id);
        if(request.action=="scan_apply") {
            let candidate=scout.pick(request.candidate_id);return candidate.success?activate(candidate.config,id):candidate;
        }
        if(request.action=="register") {
            let registered=scout.register(id,mark);if(!registered.success)return registered;
            let scanned=scout.run("quick",mark,id);if(!scanned.success)return {...scanned,registered:true};
            let candidate=scout.pick(scanned.candidate_id);return candidate.success?activate({...candidate.config,enabled:true},id):candidate;
        }
        if(index(["attach","detach"],request.action)>=0)return integration.apply?integration.apply(request,id):{success:false,error:"integration_unavailable"};
        let config=state.load(state.DIRECTORY+"/transport.json");
        if(request.action=="unregister") {
            if(!integration.references)return {success:false,error:"integration_unavailable"};
            if(config && length(integration.references(config.interface)))return {success:false,error:"references_exist"};
            if(!transport.restore({config:null,running:false},id))return {success:false,error:"remove_failed"};
            for(let path in [state.DIRECTORY+"/account.json",state.DIRECTORY+"/registration.json",state.RUNTIME+"/candidate.json",state.RUNTIME+"/preview.json",state.RUNTIME+"/transport.json"])
                if(!state.remove(path))return {success:false,error:"storage_unavailable"};
            return {success:true,registered:false};
        }
        if(index(["enable","disable","reconnect"],request.action)>=0) {
            if(!config)return {success:false,error:"selection_required"};
            if(request.action=="reconnect" && config.enabled!==true)return {success:false,error:"service_disabled"};
            return activate({...config,enabled:request.action!="disable"},id);
        }
        return {success:false,error:"unsupported_action"};
    }
    return {snapshot,restore,perform,validate:integration.validate};
}
return {status,hooks,activate,refresh_health};
