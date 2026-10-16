// Only explicit dashboard choices belong on flash; restart snapshots stay in RAM.
let fs = require("fs");
const PATH = getenv("TRAFIRA_SELECTOR_STATE_FILE") || "/etc/trafira/selector-state.json";
const MAX_BYTES = 65536;
function failure(error, applied) { return { success: false, error, applied: applied === true }; }
function valid_tag(value) { return type(value) == "string" && length(value) > 0 && length(value) <= 1024; }
function read() {
    let info = fs.lstat(PATH);
    if (!info || info.type != "file" || info.size > MAX_BYTES) return {};
    let file = fs.open(PATH, "r");
    if (!file) return {};
    let raw = file.read(MAX_BYTES + 1); file.close();
    if (raw == null || length(raw) > MAX_BYTES) return {};
    let value;
    try { value = json(raw); } catch (e) { return {}; }
    if (type(value) != "object") return {};
    let result = {};
    for (let group, selected in value)
        if (valid_tag(group) && valid_tag(selected)) result[group] = selected;
    return result;
}
function member(proxy, selected) {
    return type(proxy) == "object" && type(proxy.type) == "string" &&
        lc(proxy.type) == "selector" && type(proxy.all) == "array" &&
        valid_tag(selected) && index(proxy.all, selected) >= 0;
}
function write(value) {
    let text = sprintf("%J", value);
    if (length(text) > MAX_BYTES) return false;
    let info = fs.lstat(PATH);
    if (info && info.type != "file") return false;
    if (info && info.size <= MAX_BYTES && (info.mode & 511) == 384 && fs.readfile(PATH) == text) return true;
    // The stable lock protects this staging file and read/merge/rename sequence.
    let temporary = PATH + ".tmp", staged = fs.lstat(temporary);
    if (staged && (staged.type != "file" || !fs.unlink(temporary))) return false;
    let file = fs.open(temporary, "wex", 384);
    if (!file) return false;
    let ok = file.write(text) == length(text);
    file.flush(); file.close();
    // ucode 20250529 inverts fflush()'s result; verify bytes after closing.
    if (fs.readfile(temporary) != text || !fs.chmod(temporary, 384) || system("sync") != 0) ok = false;
    if (ok) ok = fs.rename(temporary, PATH);
    if (ok) ok = system("sync") == 0;
    if (!ok) fs.unlink(temporary);
    return ok;
}
function choose(group, selected, get_proxies, select) {
    if (!valid_tag(group) || !valid_tag(selected)) return failure("invalid_selector_choice");
    let parent = substr(PATH, 0, rindex(PATH, "/"));
    if (!fs.stat(parent) && !fs.mkdir(parent, 448)) return failure("selector_state_unavailable");
    // Keep the lock inode stable. Hold it over the API call as well, so concurrent
    // choices for one group are persisted in the same order as their runtime PUTs.
    let lock = fs.open(PATH + ".lock", "ae", 384);
    if (!lock) return failure("selector_state_unavailable");
    if (!lock.lock("x")) { lock.close(); return failure("selector_state_busy"); }
    let result;
    try {
        let payload = get_proxies();
        let proxies = type(payload) == "object" && type(payload.proxies) == "object" ? payload.proxies : {};
        if (!member(proxies[group], selected)) result = failure("invalid_selector_choice");
        else {
            result = select();
            if (type(result) != "object") result = failure("selector_api_failed");
            if (result.success === true) {
                // Absent groups may only be temporarily disabled. Keep their
                // well-formed choices; apply() validates against the new config.
                let current = read();
                current[group] = selected;
                if (!write(current)) result = failure("selector_state_not_saved", true);
            }
        }
    } catch (e) { result = failure("selector_state_error"); }
    lock.close();
    return result;
}
function apply(config) {
    let snapshot = read();
    for (let outbound in type(config.outbounds) == "array" ? config.outbounds : []) {
        if (type(outbound) != "object" || outbound.type != "selector" || type(outbound.outbounds) != "array") continue;
        let selected = snapshot[outbound.tag];
        if (valid_tag(selected) && index(outbound.outbounds, selected) >= 0) outbound.default = selected;
    }
    return config;
}
return { read, choose, apply };
