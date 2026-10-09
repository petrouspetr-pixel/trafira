let common=require("core.common");
const TYPES=["settings","section","server","subscription_url","section_interface","urltest","priority_group","priority_level"];
function name_valid(name) { return type(name)=="string" && length(trim(name))>0 && length(name)<=128 && !match(name,/[\x00-\x1f]/); }
function validate(document) {
    let errors=[];
    if(type(document)!="object" || document.schema!=1) return {valid:false,errors:["unsupported_schema"]};
    for(let key in document)
        if(index(["schema","name","created_at","config"],key)<0) push(errors,"unknown_document_field");
    if(!name_valid(document.name)) push(errors,"invalid_name");
    if(document.created_at!=null && (type(document.created_at)!="int" || document.created_at<0)) push(errors,"invalid_created_at");
    if(type(document.config)!="array" || !length(document.config) || length(document.config)>2048)
        return {valid:false,errors:["invalid_sections"]};
    let seen={},settings=0;
    for(let section in document.config) {
        if(type(section)!="object" || type(section[".name"])!="string" || !match(section[".name"],/^[A-Za-z0-9_]{1,128}$/) || index(TYPES,section[".type"])<0) {
            push(errors,"invalid_section"); continue;
        }
        if(seen[section[".name"]]) push(errors,"duplicate_section");
        seen[section[".name"]]=true;
        if(section[".type"]=="settings") { settings++;if(section[".name"]!="settings") push(errors,"invalid_settings_name"); }
        for(let key,value in section) {
            if(index([".name",".type",".anonymous",".index"],key)>=0) continue;
            if(!match(key,/^[A-Za-z0-9_]{1,128}$/)) push(errors,"invalid_option_name");
            let items=type(value)=="array"?value:[value];
            if(length(items)>8192) push(errors,"too_many_list_items");
            for(let item in items)
                if(index(["string","int","bool"],type(item))<0 || (type(item)=="string" && index(item,"\x00")>=0)) push(errors,"invalid_option_value");
        }
    }
    if(settings!=1) push(errors,"one_settings_section_required");
    if(length(sprintf("%J",document))>1048576) push(errors,"profile_too_large");
    return {valid:length(errors)==0,errors};
}
function scalar(value) { return value===true?"1":value===false?"0":common.as_string(value); }
function quote(value) { return "'"+replace(scalar(value),/'/g,"'\\''")+"'"; }
function to_uci(sections) {
    let output="";
    for(let section in sections) {
        output+="config "+section[".type"]+" "+quote(section[".name"])+"\n";
        for(let key,value in section) {
            if(substr(key,0,1)==".") continue;
            if(type(value)=="array") for(let item in value) output+="\tlist "+key+" "+quote(item)+"\n";
            else output+="\toption "+key+" "+quote(value)+"\n";
        }
        output+="\n";
    }
    return output;
}
function fixture(sections) {
    let output={};
    for(let section in sections) {
        let kind=section[".type"];
        if(kind=="settings") output.settings=section;
        else { output[kind]=output[kind]||[];push(output[kind],section); }
    }
    return output;
}
function diff(before,after) {
    let old={},next={},changes=[];
    for(let section in before || []) old[section[".name"]]=section;
    for(let section in after || []) next[section[".name"]]=section;
    let names=keys(old);
    for(let name in keys(next)) if(index(names,name)<0) push(names,name);
    for(let name in names) {
        if(!old[name] || !next[name]) { push(changes,{section:name,change:old[name]?"removed":"added"});continue; }
        let options=keys(old[name]);
        for(let key in keys(next[name])) if(index(options,key)<0) push(options,key);
        for(let key in options) {
            if(substr(key,0,1)=="." && key!=".type") continue;
            if(sprintf("%J",old[name][key])!=sprintf("%J",next[name][key]))
                push(changes,{section:name,option:key,change:"changed",before:"***",after:"***"});
        }
    }
    return changes;
}
return {TYPES,name_valid,validate,to_uci,fixture,diff};
