// Pure selection policy. Source adapters, never the browser, supply artifacts.
function safe(value) {return type(value)=="string" && length(value)<=128 && match(value,/^[A-Za-z0-9_.+-]+$/);}
function stable(item) {
    return type(item)=="object" && item.stable===true && !item.draft &&
        safe(item.version) && !match(lc(item.version),/(alpha|beta|rc|nightly|dev)/) &&
        safe(item.variant) && safe(item.architecture) && safe(item.package_type);
}
function identifier(item) {return join("~",[item.variant,item.architecture,item.package_type,item.version]);}
function incompatibility(item,env) {
    if(item.variant!=env.variant)return "wrong_variant";
    if(item.architecture!=env.architecture)return "wrong_architecture";
    if(item.package_type!=env.package_type)return "wrong_package_type";
    if(!item.asset_url && !item.repository_package)return "artifact_unavailable";
    return "";
}
function catalog(releases,environment) {
    if(type(releases)!="array" || type(environment)!="object")return {entries:[],unavailable_reason:"invalid_catalog"};
    if(length(releases)>100 || length(sprintf("%J",releases))>2097152)return {entries:[],unavailable_reason:"catalog_too_large"};
    let entries=[],seen={};
    for(let item in releases) {
        if(!stable(item))continue;
        let id=identifier(item),reason=incompatibility(item,environment);
        if(seen[id])continue;
        seen[id]=true;
        push(entries,{id,version:item.version,variant:item.variant,architecture:item.architecture,
            package_type:item.package_type,available:reason=="",reason,release_url:item.release_url||""});
    }
    return {entries,unavailable_reason:length(entries)?"":"no_available_versions"};
}
function resolve(id,releases,environment) {
    if(type(id)!="string" || length(id)>520)return null;
    let result=catalog(releases,environment);
    for(let entry in result.entries)if(entry.id==id && entry.available)
        for(let item in releases)if(stable(item) && identifier(item)==id && incompatibility(item,environment)=="")return item;
    return null;
}
function select(releases,environment,pin) {
    if(pin && pin.version && pin.variant!=environment.variant)return {error:"pinned_variant_mismatch"};
    for(let entry in catalog(releases,environment).entries) {
        if(!entry.available || (pin && pin.version && entry.version!=pin.version))continue;
        return {candidate:resolve(entry.id,releases,environment)};
    }
    return {error:pin && pin.version?"pinned_version_unavailable":"no_available_versions"};
}
function from_github(releases,env) {
    if(type(releases)!="array" || length(releases)>100 || length(sprintf("%J",releases))>2097152)return null;
    if(type(env)!="object" || !safe(env.architecture) || index(["extended","extended-compressed"],env.variant)<0)return null;
    let compressed=env.variant=="extended-compressed";
    if(compressed && !safe(env.binary_architecture))return null;
    let suffix=compressed?"linux-"+env.binary_architecture+"-compressed.tar.gz":"_openwrt_"+env.architecture+"."+env.package_type;
    let result=[];
    for(let release in releases) {
        if(type(release)!="object" || release.draft || release.prerelease || !safe(release.tag_name))continue;
        let version=replace(release.tag_name,/^v/,""),prefix="https://github.com/shtorm-7/sing-box-extended/releases/download/"+release.tag_name+"/";
        if(!match(version,/^[0-9]+\.[0-9]+\.[0-9]+/) || match(lc(version),/(alpha|beta|rc|nightly|dev)/))continue;
        for(let asset in type(release.assets)=="array"?release.assets:[]) {
            if(type(asset)!="object" || !safe(asset.name) || substr(asset.name,0,18)!="sing-box-extended_" && substr(asset.name,0,18)!="sing-box-extended-")continue;
            if(substr(asset.name,-length(suffix))!=suffix || asset.browser_download_url!=prefix+asset.name)continue;
            if(type(asset.size)!="int" || asset.size<=0)continue;
            let digest=asset.digest||"";
            if(digest && !match(digest,/^sha256:[a-fA-F0-9]{64}$/))continue;
            push(result,{version,tag:release.tag_name,stable:true,variant:env.variant,architecture:env.architecture,package_type:env.package_type,
                asset_name:asset.name,asset_url:asset.browser_download_url,asset_size:asset.size,sha256:digest?lc(substr(digest,7)):"",
                release_url:"https://github.com/shtorm-7/sing-box-extended/releases/tag/"+release.tag_name});
            break;
        }
    }
    return result;
}
function from_packages(packages,env) {
    if(type(packages)!="array" || length(packages)>100 || length(sprintf("%J",packages))>2097152)return null;
    if(type(env)!="object" || index(["stable","tiny"],env.variant)<0)return null;
    let name=env.variant=="tiny"?"sing-box-tiny":"sing-box",result=[];
    for(let pkg in packages) {
        if(type(pkg)!="object" || pkg.name!=name || !safe(pkg.version) || !safe(pkg.arch))continue;
        push(result,{version:pkg.version,variant:env.variant,architecture:pkg.arch,package_type:env.package_type,
            stable:true,repository_package:name});
    }
    return result;
}
return {catalog,resolve,select,from_github,from_packages};
