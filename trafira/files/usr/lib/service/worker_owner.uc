// Numeric PID files are compatibility views. Only the private generation record
// authorizes cancellation; no signal is sent using an unverified PID/group.
let fs = require("fs");
const LIB = getenv("TRAFIRA_LIB") || fs.dirname(fs.dirname(sourcepath()));
const ROLES = {
    wan: ["service/initd.uc", "scheduled-start-retry-worker"],
    subscription: ["subscription/cache.uc", "deferred-bootstrap-worker"]
};
function bounded(path, limit) {
    let file = fs.open(path, "re");
    if (!file) return null;
    let text = file.read(limit + 1); file.close();
    return text != null && length(text) <= limit ? text : null;
}
function identity(pid) {
    pid = pid == null ? "self" : "" + pid;
    if (pid != "self" && !match(pid, /^[1-9][0-9]*$/)) return null;
    let raw = bounded("/proc/" + pid + "/stat", 4096);
    if (!raw) return null;
    let end = rindex(raw, ")"), start = index(raw, " ");
    if (end < 0 || start < 0) return null;
    let fields = split(trim(substr(raw, end + 1)), /\s+/);
    return {pid:substr(raw,0,start), ticks:fields[19], parent:fields[1],
        group:fields[2], session:fields[3], state:fields[0]};
}
function uuid(value) { return type(value) == "string" && match(value, /^[a-f0-9-]{36}$/); }
function token() {
    let value = trim(bounded("/proc/sys/kernel/random/uuid", 64) || "");
    return uuid(value) ? value : null;
}
function lock(path) {
    let name = path + ".guard", info = fs.lstat(name);
    if (info && info.type != "file") return null;
    let file = fs.open(name, "ae", 384);
    if (!file) return null;
    if (file.lock("x")) return file;
    file.close(); return null;
}
function read(path) {
    try { return json(bounded(path + ".owner.json", 16384) || ""); }
    catch (e) { return null; }
}
function valid(record, role) {
    if (type(record) != "object" || record.version != 1 || record.role != role ||
        !ROLES[role] || !uuid(record.token)) return false;
    for (let field in ["pid", "ticks", "group", "session"])
        if (type(record[field]) != "string" || !match(record[field], /^[1-9][0-9]*$/)) return false;
    return record.group == record.pid && record.session == record.pid;
}
function same(a, b) {
    if (!a || !b) return false;
    for (let field in ["pid", "ticks", "group", "session", "role", "token"])
        if (a[field] != b[field]) return false;
    return true;
}
function marked(process, generation) {
    let text = bounded("/proc/" + process.pid + "/environ", 131072);
    return text != null && index(split(text, "\x00"), "TRAFIRA_WORKER_TOKEN=" + generation) >= 0;
}
function role_matches(process, role) {
    let text = bounded("/proc/" + process.pid + "/cmdline", 8192), expected = ROLES[role];
    if (text == null || !expected) return false;
    let args = split(text, "\x00");
    return index(args, LIB + "/" + expected[0]) >= 0 && index(args, expected[1]) >= 0;
}
function members(record, trust_group) {
    let result = {owned:[], unknown:0};
    for (let name in fs.lsdir("/proc") || []) {
        if (!match(name, /^[1-9][0-9]*$/)) continue;
        let item = identity(name);
        if (!item || item.state == "Z" || item.group != record.group || item.session != record.session) continue;
        if (trust_group || marked(item, record.token)) push(result.owned, item);
        else result.unknown++;
    }
    return result;
}
function current(path, role) {
    let record = read(path);
    if (!valid(record, role)) return null;
    let leader = identity(record.pid);
    // A live reused PID is never a reason to adopt its process group.
    if (leader && (leader.ticks != record.ticks || leader.group != record.group ||
        leader.session != record.session)) return null;
    if (leader && leader.state != "Z") {
        if (!role_matches(leader, role) || !marked(leader, record.token)) return null;
        record.orphaned = false; return record;
    }
    let children = members(record, false);
    if (!length(children.owned) && !children.unknown) return null;
    record.orphaned = true;
    record.unverified = !length(children.owned);
    return record;
}
function atomic(path, text) {
    let temporary = path + ".publish.tmp";
    fs.unlink(temporary);
    let file = fs.open(temporary, "wex", 384);
    if (!file) return false;
    let written = file.write(text); file.close();
    let ok = written == length(text) && bounded(temporary, 16384) == text && fs.rename(temporary, path);
    fs.unlink(temporary);
    return ok;
}
function discard(path) {
    fs.unlink(path); fs.unlink(path + ".owner.json");
}
function publish(path, pid, role, generation) {
    if (!uuid(generation) || !ROLES[role]) return null;
    let deadline = clock(true)[0] + 2, process;
    do {
        process = identity(pid);
        if (process && process.state != "Z" && process.pid == process.group &&
            process.pid == process.session && role_matches(process, role) && marked(process, generation)) break;
        process = null; sleep(10);
    } while (clock(true)[0] < deadline);
    if (!process) return null;
    let record = {version:1, role, pid:process.pid, ticks:process.ticks,
        group:process.group, session:process.session, token:generation};
    // The compatibility view cannot release the gate: JSON is committed last.
    if (!atomic(path, record.pid + "\n") || !atomic(path + ".owner.json", sprintf("%J", record))) return null;
    return record;
}
function wait(path, role, launcher_pid, launcher_ticks) {
    let self = identity(), deadline = clock(true)[0] + 5;
    if (!self || !uuid(getenv("TRAFIRA_WORKER_TOKEN"))) return null;
    do {
        let record = current(path, role);
        if (record && record.pid == self.pid && record.ticks == self.ticks &&
            record.token == getenv("TRAFIRA_WORKER_TOKEN")) return record;
        let launcher = identity(launcher_pid);
        if (!launcher || launcher.state == "Z" || launcher.ticks != launcher_ticks) return null;
        sleep(10);
    } while (clock(true)[0] < deadline);
    return null;
}
function owned(path, record) { return same(current(path, record.role), record); }
function forget_locked(path, record) {
    if (!same(read(path), record)) return false;
    if (!fs.unlink(path + ".owner.json")) return false;
    if (bounded(path, 64) == record.pid + "\n") fs.unlink(path);
    return true;
}
function forget(path, record) {
    let held = lock(path);
    if (!held) return false;
    let result = false;
    try { result = forget_locked(path, record); } catch (e) {}
    held.close(); return result;
}
function kill_process(item) {
    let now = identity(item.pid);
    if (!now || now.ticks != item.ticks || now.group != item.group || now.session != item.session) return;
    system("kill -KILL " + now.pid + " 2>/dev/null");
}
function kill_unpublished(pid, role, generation) {
    let item = identity(pid);
    if (item && item.pid == item.group && item.pid == item.session &&
        role_matches(item, role) && marked(item, generation)) kill_process(item);
}
function cancel_locked(path, role) {
    let record = current(path, role);
    if (!record) { discard(path); return {ok:true, owner:null}; }
    let self = identity();
    if (!self || self.group == record.group || record.unverified) return {ok:false, owner:record};
    let deadline = clock(true)[0] + 2, trusted = !record.orphaned;
    do {
        let group = members(record, trusted);
        // No freezing: a killed canceler must never leave a stopped group.
        for (let item in group.owned) if (item.pid != record.pid) kill_process(item);
        for (let item in group.owned) if (item.pid == record.pid) kill_process(item);
        trusted = false;
        group = members(record, false);
        if (!length(group.owned) && !group.unknown) {
            return {ok:forget_locked(path, record), owner:record};
        }
        sleep(20);
    } while (clock(true)[0] < deadline);
    // Keep the generation available for a later cancellation attempt.
    return {ok:false, owner:record};
}
function cancel(path, role, held) {
    let own_lock = !held;
    held = held || lock(path);
    if (!held) return {ok:false, owner:null};
    let result = {ok:false, owner:null};
    try { result = cancel_locked(path, role); } catch (e) {}
    if (own_lock) held.close();
    return result;
}
return {identity, token, lock, current, publish, wait, owned, forget, discard, cancel, kill_unpublished};
