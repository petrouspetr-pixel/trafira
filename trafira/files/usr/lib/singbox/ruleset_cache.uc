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
function validate(rule, file, session) {
    let bytes = size(file);
    if (bytes <= 0 || bytes > MAX_FILE) return false;
    // Only one bootstrap operation owns this memo. Content and format, rather
    // than pathname or timestamps, bind aliases and the failure-policy baseline.
    let digest = session ? require("singbox.provenance").hash_file(file) : null;
    let key = digest ? (rule.format || "binary") + "\n" + digest : null;
    if (key && session[key] === true) return true;
    let tmp = output("mktemp /tmp/trafira-ruleset-check.XXXXXX");
    if (!tmp) return false;
    let valid = success(["sing-box", "rule-set", rule.format == "source" ? "compile" : "decompile", file, "-o", tmp]);
    fs.unlink(tmp);
    if (session) {
        if (!digest || require("singbox.provenance").hash_file(file) != digest) return false;
        if (valid && length(keys(session)) < 512) session[key] = true;
    }
    return valid;
}
function apply(config, version, defer_validation, session) {
    if (!modern(version)) return;
    for (let rule in common.array_or_empty(config.route && config.route.rule_set)) {
        let file = path(rule);
        if (file && (defer_validation ? size(file) > 0 && size(file) <= MAX_FILE : validate(rule, file, session))) rule.initial_path = file;
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
function save_locked(rule, file, session) {
    let target = path(rule);
    if (!target || !validate(rule, file, session)) return false;
    if (success(["cmp", "-s", file, target])) return true;
    if (!success(["mkdir", "-p", CACHE_DIR]) || !success(["chmod", "700", CACHE_DIR])) return false;
    let bytes = size(file);
    // Bound the final cache, but reserve physical space for the entire staged
    // copy while the old file still exists. Full caches must remain updatable.
    if (usage() - size(target) + bytes > MAX_TOTAL || !space_ok(bytes)) return false;
    let staged = output(command(["mktemp", CACHE_DIR + "/.stage.XXXXXX"]));
    if (!staged) return false;
    let ok = success(["cp", file, staged]) && success(["chmod", "600", staged]) && fs.rename(staged, target);
    fs.unlink(staged);
    return !!ok;
}
function cache_lock() {
    if (!success(["mkdir", "-p", CACHE_DIR]) || !success(["chmod", "700", CACHE_DIR])) return null;
    let lock = fs.open(CACHE_DIR + "/.cache.lock", "ae", 384);
    if (!lock) return null;
    if (!lock.lock("x")) { lock.close(); return null; }
    return lock;
}
function save(rule, file, session) {
    let lock = cache_lock();
    if (!lock) return false;
    let ok = false;
    try { ok = save_locked(rule, file, session); } catch (e) {}
    lock.close();
    return ok;
}
function protect(config, session) {
    let lock = cache_lock();
    if (!lock) return false;
    let ok = true;
    try {
        for (let rule in common.array_or_empty(config.route && config.route.rule_set)) {
            if (rule.type != "remote" || rule.http_client == null) continue;
            let file = path(rule);
            if (!file || !validate(rule, file, session)) { ok = false; break; }
            let info = fs.lstat(file);
            // Reused old URLs need the same publication grace as new copies.
            // Avoid repeated metadata writes during rapid reloads.
            if (time() - info.mtime > 120 && !success(["touch", file])) { ok = false; break; }
            rule.initial_path = file;
        }
    } catch (e) { ok = false; }
    lock.close();
    return ok;
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
    let guard = cache_lock();
    if (!guard) return false;
    // Bootstrap can prepare another configuration while the current core runs.
    // Keep newly published snapshots past its bounded 90-second preparation and
    // publication window, even if this worker captured the previous config.
    for (let name in fs.lsdir(CACHE_DIR) || []) {
        let target = CACHE_DIR + "/" + name;
        let info = fs.lstat(target);
        if (!info || info.type != "file" || active[target]) continue;
        if ((match(name, /^[a-f0-9]{64}[.]snapshot$/) && time() - info.mtime > 300) ||
            (match(name, /^[.]stage[.][A-Za-z0-9]+$/) && time() - info.mtime > 3600))
            fs.unlink(target);
    }
    guard.close();
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

// A cheap inventory, not a validation pass: initial_path only describes the
// saved configuration, never proves that the live process loaded these bytes.
function report(config, version) {
    let entries = [];
    let compatible = true;
    for (let rule in common.array_or_empty(config && config.route && config.route.rule_set)) {
        let file = path(rule);
        if (!file) continue;
        if (rule.http_client == null) compatible = false;
        let info = fs.lstat(file);
        let present = info && info.type == "file";
        push(entries, {
            tag: rule.tag || "", present: !!present,
            bytes: present ? info.size : 0, mtime: present ? info.mtime : null,
            configured_initial: !!(present && rule.initial_path == file)
        });
    }
    return { supported: !!modern(version), available: type(config) == "object",
        preparable: !!modern(version) && compatible && length(entries) > 0,
        entries, total_bytes: usage(), quota_bytes: MAX_TOTAL, max_file_bytes: MAX_FILE };
}

return { apply, save, refresh, path, report, validate, protect };
