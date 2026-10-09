let fs = require("fs");
let common = require("core.common");
function sanitize(origin) {
    let result = {};
    for (let key in ["kind", "section", "list_tag"])
        if (type(origin) == "object" && type(origin[key]) == "string")
            result[key] = substr(origin[key],0,128);
    return result;
}
function annotate(rule, origin) { rule.__trafira_origin = sanitize(origin); return rule; }
function strip(value) {
    if (type(value) == "object") {
        delete value.__trafira_origin;
        for (let key in keys(value)) strip(value[key]);
    }
    else if (type(value) == "array") for (let item in value) strip(item);
}
function extract(config) {
    let result = {schema:1,route:[],dns:[]};
    for (let kind in ["route","dns"])
        for (let rule in common.array_or_empty(common.object_or_empty(config[kind]).rules)) {
            push(result[kind], sanitize(rule.__trafira_origin || {kind:"system"}));
            strip(rule);
        }
    return result;
}
function hash_file(path) {
    let quoted = "'" + replace(path, /'/g, "'\\''") + "'";
    let pipe = fs.popen("sha256sum " + quoted + " 2>/dev/null", "r");
    if (!pipe) return null;
    let output = pipe.read(128); let status = pipe.close();
    let found = match(output || "", /^([a-f0-9]{64}) /);
    return status == 0 && found ? found[1] : null;
}
function save(path, origins) {
    let digest = hash_file(path);
    if (!digest) return false;
    origins.config_digest = digest;
    let target = path + ".provenance.json", temporary = target + ".tmp";
    if (fs.writefile(temporary,sprintf("%J\n",origins)) == null) return false;
    fs.chmod(temporary,384);
    return fs.rename(temporary,target);
}
function load(path) {
    let map = common.read_json_file(path + ".provenance.json");
    if (type(map) != "object" || map.schema != 1 || !map.config_digest || map.config_digest != hash_file(path)) return null;
    return map;
}
return {annotate,extract,save,load,hash_file};
