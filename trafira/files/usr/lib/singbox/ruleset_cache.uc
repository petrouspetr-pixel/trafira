// Validated, bounded startup snapshots. The running core still owns remote updates.
let fs = require("fs");
let common = require("core.common");

const CACHE_DIR = getenv("TRAFIRA_RULESET_CACHE_DIR") || "/etc/trafira/ruleset-cache";
const MAX_FILE = 4 * 1024 * 1024;
const MAX_TOTAL = 8 * 1024 * 1024;
const RESERVE = 4 * 1024 * 1024;

function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function output(cmd) {
    let pipe = fs.popen(cmd, "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    return pipe.close() == 0 ? trim(data || "") : "";
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function warning(message) { warn("Rule-set startup cache: ", message, "\n"); }
function size(path) {
    let info = fs.lstat(path);
    return info && info.type == "file" ? info.size : 0;
}
function modern(version) {
    let parts = match("" + version, /^([0-9]+)[.]([0-9]+)/);
    return parts && (int(parts[1]) > 1 || (int(parts[1]) == 1 && int(parts[2]) >= 14));
}
function path(rule) {
    if (rule.type != "remote" || !rule.url || !match(rule.url, /^https?:\/\//)) return "";
    let hash = output("printf %s " + quote(rule.url + "\n" + (rule.format || "binary")) + " | sha256sum");
    hash = substr(hash, 0, 64);
    return match(hash, /^[a-f0-9]{64}$/) ? CACHE_DIR + "/" + hash + ".snapshot" : "";
}
function validate(rule, file) {
    let bytes = size(file);
    if (bytes <= 0 || bytes > MAX_FILE) return false;
    let tmp = output("mktemp /tmp/trafira-ruleset-check.XXXXXX");
    if (!tmp) return false;
    let valid = success(["sing-box", "rule-set", rule.format == "source" ? "compile" : "decompile", file, "-o", tmp]);
    fs.unlink(tmp);
    return valid;
}
function apply(config, version) {
    if (!modern(version)) return;
    for (let rule in common.array_or_empty(config.route && config.route.rule_set)) {
        let file = path(rule);
        if (file && validate(rule, file)) rule.initial_path = file;
    }
}
function usage() {
    let total = 0;
    for (let name in fs.lsdir(CACHE_DIR) || []) total += size(CACHE_DIR + "/" + name);
    return total;
}
function space_ok(bytes) {
    let rows = split(output(command(["df", "-Pk", CACHE_DIR])), "\n");
    let fields = split(trim(rows[length(rows) - 1] || ""), /[ \t]+/);
    return length(fields) >= 4 && int(fields[3]) * 1024 >= bytes + RESERVE;
}
function save(rule, file) {
    let target = path(rule);
    if (!target || !validate(rule, file)) return false;
    if (success(["cmp", "-s", file, target])) return true;
    if (!success(["mkdir", "-p", CACHE_DIR]) || !success(["chmod", "700", CACHE_DIR])) return false;
    let bytes = size(file);
    // Count both old and staged copies: atomic replacement temporarily needs both.
    if (usage() + bytes > MAX_TOTAL || !space_ok(bytes)) return false;
    let staged = output(command(["mktemp", CACHE_DIR + "/.stage.XXXXXX"]));
    if (!staged) return false;
    let ok = success(["cp", file, staged]) && success(["chmod", "600", staged]) && fs.rename(staged, target);
    fs.unlink(staged);
    return !!ok;
}
function refresh(config, proxy) {
    let rules = filter(common.array_or_empty(config.route && config.route.rule_set),
        (rule) => rule.type == "remote" && rule.http_client != null);
    // Legacy configurations cannot use initial_path; do not download unused copies.
    if (length(rules) == 0) return true;
    let active = {};
    for (let rule in rules) {
        let target = path(rule);
        if (target) active[target] = true;
        if (rule.initial_path) active[rule.initial_path] = true;
    }
    // Called under the list-update worker's serialization. Never prune a file
    // referenced by the active config; leave recent staging files alone.
    for (let name in fs.lsdir(CACHE_DIR) || []) {
        let target = CACHE_DIR + "/" + name;
        let info = fs.lstat(target);
        if (!info || info.type != "file" || active[target]) continue;
        if (match(name, /^[a-f0-9]{64}[.]snapshot$/) ||
            (match(name, /^[.]stage[.][A-Za-z0-9]+$/) && time() - info.mtime > 3600))
            fs.unlink(target);
    }
    let seen = {};
    let ok = true;
    for (let rule in rules) {
        let target = path(rule);
        if (!target || seen[target]) continue;
        seen[target] = true;
        let tmp = output("mktemp /tmp/trafira-ruleset-download.XXXXXX");
        if (!tmp) { ok = false; continue; }
        let args = ["curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "10",
            "--max-time", "30", "--max-filesize", "" + MAX_FILE, "--output", tmp];
        if (proxy) push(args, "--proxy", "http://" + proxy, "--noproxy", "");
        else push(args, "--noproxy", "*");
        push(args, rule.url);
        if (!success(args) || !save(rule, tmp)) {
            warning("could not refresh '" + rule.tag + "'; keeping its previous snapshot (download, validation or storage limit)");
            ok = false;
        }
        fs.unlink(tmp);
    }
    return ok;
}

return { apply, save, refresh, path };
