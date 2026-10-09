// SPDX-License-Identifier: GPL-3.0-only
const NAMES=["trafira-warp-awg","trafira-warp-scout","luci-app-trafira-warp"];
function fail(error){return {success:false,error};}
function version(value){return type(value)=="string" && match(value,/^v?[0-9]+\.[0-9]+\.[0-9]+$/);}
function at_least(actual,minimum) {
    if(!version(actual) || !version(minimum))return false;
    let a=map(split(replace(actual,/^v/,""),"."),(v)=>int(v)),b=map(split(replace(minimum,/^v/,""),"."),(v)=>int(v));
    for(let i=0;i<3;i++)if(a[i]!=b[i])return a[i]>b[i];
    return true;
}
function select(manifest,arch,manager,current) {
    if(arch!="aarch64_cortex-a53" || index(["apk","opkg"],manager)<0)return fail("unsupported_platform");
    if(type(manifest)!="object" || manifest.schema!=1 || !version(manifest.family_version) || !version(manifest.minimum_trafira_version) || type(manifest.packages)!="array" || length(manifest.packages)>6)return fail("invalid_manifest");
    if(!at_least(current,manifest.minimum_trafira_version))return fail("trafira_update_required");
    let selected=[],seen={};
    for(let item in manifest.packages) {
        if(type(item)!="object")return fail("invalid_manifest");
        if(item.manager!=manager)continue;
        if(index(NAMES,item.name)<0 || seen[item.name] || item.arch!=arch || type(item.version)!="string" || !match(item.version,/^[0-9][A-Za-z0-9.+_-]{0,95}$/) ||
            type(item.sha256)!="string" || !match(item.sha256,/^[a-f0-9]{64}$/) || type(item.file)!="string" || !match(item.file,/^[a-zA-Z0-9][a-zA-Z0-9_.+-]{0,159}\.(apk|ipk)$/) ||
            !match(item.file,manager=="apk"?/\.apk$/:/\.ipk$/) || type(item.installed_size)!="int" || item.installed_size<=0 || item.installed_size>67108864 || type(item.size)!="int" || item.size<=0 || item.size>33554432)return fail("invalid_manifest");
        seen[item.name]=true;push(selected,item);
    }
    if(length(selected)!=3)return fail("incomplete_family");
    sort(selected,(a,b)=>index(NAMES,a.name)-index(NAMES,b.name));
    return {success:true,family_version:manifest.family_version,packages:selected,manager,arch};
}
function release_asset(release,name) {
    if(type(release)!="object" || release.draft || release.prerelease || type(release.tag_name)!="string" || !match(release.tag_name,/^[A-Za-z0-9_.-]{1,96}$/) || type(release.assets)!="array")return null;
    let prefix="https://github.com/petrouspetr-pixel/trafira/releases/download/"+release.tag_name+"/",found=null;
    for(let asset in release.assets)if(asset.name==name) {
        if(found || asset.browser_download_url!=prefix+name || type(asset.size)!="int" || asset.size<=0 || asset.size>33554432)return null;
        found={url:asset.browser_download_url,size:asset.size};
    }
    return found;
}
function install(selection,hooks) {
    if(!selection?.success)return fail("invalid_selection");
    let staged=hooks.stage(selection);if(!staged)return fail("package_verification_failed");
    let previous=hooks.stage_previous();if(!previous)return fail("rollback_unavailable");
    let original=hooks.snapshot();if(!original)return fail("snapshot_failed");
    if(hooks.space && !hooks.space(staged,previous,original))return fail("insufficient_space");
    if(hooks.journal && !hooks.journal(original,previous,staged))return fail("journal_failed");
    let result;
    try {
        if(!hooks.stop())result=fail("stop_failed");
        else if(!hooks.install(staged))result=fail("install_failed");
        else if(!hooks.verify(staged))result=fail("verification_failed");
        else if(!hooks.resume(original))result=fail("restart_failed");
        else if(!hooks.commit(staged,previous))result=fail("commit_failed");
        else result={success:true};
    }catch(e){result=fail("install_failed");}
    if(!result.success) {
        let restored=false;try {restored=hooks.restore(previous,original)===true;}catch(e){}
        result={...result,restored,rollback_error:!restored};
    }
    if((result.success || result.restored) && hooks.clear && !hooks.clear())return {...fail("journal_cleanup_failed"),recovery_pending:true};
    return result;
}
return {NAMES,select,release_asset,install,at_least};
