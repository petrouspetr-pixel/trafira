// Policy shared by the version installer and its failure-path tests.
let versions=require("components.core_versions");
function fail(error){return {success:false,error};}
function normalized(version){return replace(""+version,/\+.*$/,"");}
function prepare(request,hooks) {
    let current=hooks.current(),digest=hooks.digest();
    if(current!=request.expected_current_version || !digest)return fail("conflict");
    let env=hooks.environment(),releases=hooks.fetch(env);
    let candidate=versions.resolve(request.candidate_id,releases,env);
    if(!candidate)return fail("candidate_unavailable");
    let archive=hooks.download(candidate);
    if(!archive)return fail("candidate_download_failed");
    let core=hooks.stage(archive,candidate);
    if(!core || !core.success)return core||fail("candidate_stage_failed");
    if(!hooks.check(core))return fail("candidate_check_failed");
    if(hooks.current()!=current || hooks.digest()!=digest)return fail("conflict");
    return {success:true,request,candidate,archive,core,expected_digest:digest,
        original_version:current,original_pin:hooks.pin_read()};
}
function finish(prepared,hooks) {
    if(!prepared || !prepared.success)return fail("invalid_selection");
    if(normalized(hooks.current())!=normalized(prepared.core.version))return fail("installed_version_mismatch");
    if(prepared.candidate.repository_package && hooks.package_version(prepared.candidate.repository_package)!=prepared.candidate.version)
        return fail("installed_version_mismatch");
    return hooks.pin_write(prepared.request.pin?{version:prepared.candidate.version,variant:prepared.candidate.variant}:null);
}
return {prepare,finish};
