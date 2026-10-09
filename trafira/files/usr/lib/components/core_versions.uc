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
return {catalog,resolve,select};
