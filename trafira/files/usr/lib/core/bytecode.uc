// Optional private RAM cache. Original modules and import paths stay intact.
let fs = require("fs");
const ALLOWED = [ "diagnostics/runtime.uc", "config/profile_cli.uc", "config/gaming_cli.uc", "components/core_cli.uc" ];
const LIMIT = 524288;
const MAX_FILE = 131072;

function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function status(code) { return code == null || code < 0 ? 1 : code > 255 ? code >> 8 : code; }
function bounded(path, limit) {
    let s = fs.lstat(path);
    return s != null && s.type == "file" && s.size <= limit ? fs.readfile(path) : null;
}
function identity() {
    let s = fs.stat("/proc/self/exe");
    return s == null ? null : sprintf("%J", [ s.dev, s.inode, s.size, s.mtime, s.ctime ]);
}
function start_time(pid) {
    if (!match("" + pid, /^[0-9]+$/)) return null;
    let m = match(fs.readfile("/proc/" + pid + "/stat") || "", /^[0-9]+ \(.*\) (.*)$/);
    return m == null ? null : split(m[1], " ")[19];
}
function private_dir(path, uid) {
    let s = fs.lstat(path);
    return s != null && s.type == "directory" && s.uid == uid && (s.mode & 511) == 448;
}
function ram_mount(path) {
    let longest = "", kind = "";
    for (let line in split(fs.readfile("/proc/mounts") || "", "\n")) {
        let parts = split(line, " ");
        let mount = parts[1] || "";
        if (mount != "" && (path == mount || index(path, mount == "/" ? "/" : mount + "/") == 0) && length(mount) > length(longest)) {
            longest = mount;
            kind = parts[2];
        }
    }
    return kind == "tmpfs";
}
function context() {
    if (getenv("TRAFIRA_BYTECODE_CACHE") == "0") return null;
    let uid = fs.stat("/proc/self")?.uid;
    let test = getenv("TRAFIRA_BYTECODE_TEST_ROOT") || "";
    let marker = test + "/.trafira-bytecode-cache-test";
    let testing = test != "" && index(test, "/tmp/trafira-bytecode-test-") == 0 && private_dir(test, uid) && bounded(marker, 32) != null;
    if (test != "" && !testing) return null;
    if (!testing && (uid != 0 || !ram_mount("/tmp/trafira-bytecode") || fs.lstat("/tmp")?.type != "directory")) return null;
    let root = testing ? test + "/cache" : "/tmp/trafira-bytecode";
    let info = fs.readfile(testing ? test + "/meminfo" : "/proc/meminfo") || "";
    let available = match(info, /MemAvailable:[ \t]+([0-9]+)/);
    if (available == null || int(available[1]) < 16384) return null;
    // statvfs is absent in older supported ucode builds; allocation errors
    // still fail closed, and the MemAvailable gate applies on every build.
    if (type(fs.statvfs) == "function") {
        let disk = fs.statvfs(testing ? test : "/tmp");
        if (disk == null || disk.bavail * (disk.frsize || disk.bsize) < 4194304) return null;
    }
    if (fs.lstat(root) == null && !fs.mkdir(root, 0700)) return null;
    if (!private_dir(root, uid)) {
        if (testing) warn("cache root: ", sprintf("%J", fs.lstat(root)), " expected uid=", uid, "\n");
        return null;
    }
    let requested = testing ? int(getenv("TRAFIRA_BYTECODE_TEST_LIMIT") || LIMIT) : LIMIT;
    return { root, uid, limit: (requested < LIMIT ? requested : LIMIT) - 512 };
}
function unlock(root) {
    fs.unlink(root + "/lock/owner.json");
    fs.rmdir(root + "/lock");
}
function lock(c) {
    let path = c.root + "/lock";
    if (!fs.mkdir(path, 0700)) {
        if (!private_dir(path, c.uid)) return false;
        let owner;
        try { owner = json(bounded(path + "/owner.json", 512) || "null"); } catch (e) { owner = null; }
        let alive = owner != null && owner.start != null && start_time(owner.pid) == owner.start;
        let stale = time() - (fs.stat(path)?.mtime || time()) > 5;
        if (alive || !stale) return false;
        unlock(c.root);
        if (!fs.mkdir(path, 0700)) return false;
    }
    let pid = fs.readlink("/proc/self");
    let owner_data = sprintf("%J", { pid, start: start_time(pid) });
    if (fs.writefile(path + "/owner.json", owner_data) != length(owner_data)) {
        unlock(c.root);
        return false;
    }
    return true;
}
function used(root) {
    let total = 0;
    for (let path in fs.glob(root + "/*")) {
        let s = fs.lstat(path);
        if (s == null) continue;
        if (s.type == "file") total += s.size;
        else if (path != root + "/lock") return LIMIT + 1;
    }
    return total;
}
function erase(base) {
    for (let suffix in [ ".ucb", ".source", ".proof", ".json", ".part" ]) fs.unlink(base + suffix);
}
function prepare(c, lib, relative, source) {
    let text = bounded(source, MAX_FILE);
    if (text == null || index(text, "sourcepath") >= 0 || index(text, "include(") >= 0) {
        if (getenv("TRAFIRA_BYTECODE_TEST_ROOT")) warn("cache source rejected\n");
        return null;
    }
    let base = c.root + "/" + replace(relative, /\//g, "_");
    let stamp = sprintf("%J", { schema: 1, lib, relative, runtime: identity(), flags: "-s -cno-interp" });
    let code = bounded(base + ".ucb", MAX_FILE);
    if (code != null && substr(code, 0, 4) == "\x1bucb" &&
        bounded(base + ".json", 2048) == stamp && bounded(base + ".source", MAX_FILE) == text &&
        bounded(base + ".proof", MAX_FILE) == code && used(c.root) <= c.limit) return base + ".ucb";
    erase(base);
    let current = used(c.root);
    if (current + length(text) + length(stamp) + MAX_FILE > c.limit) {
        if (getenv("TRAFIRA_BYTECODE_TEST_ROOT")) warn("cache budget rejected\n");
        return null;
    }
    let exe = "/proc/" + fs.readlink("/proc/self") + "/exe";
    if (exe == null || identity() == null) return null;
    if (fs.writefile(base + ".source", text) != length(text)) { erase(base); return null; }
    // Compile an immutable snapshot with this interpreter, never a build-host ABI.
    // A file-size ulimit also bounds the compiler's temporary output.
    let rc = system("(ulimit -f 128; " + command([ exe, "-s", "-cno-interp", "-o", base + ".part", base + ".source" ]) + ") >/dev/null 2>&1");
    code = bounded(base + ".part", MAX_FILE);
    if (status(rc) != 0 || code == null || substr(code, 0, 4) != "\x1bucb" || bounded(source, MAX_FILE) != text ||
        current + length(text) + length(stamp) + 2 * length(code) > c.limit) {
        if (getenv("TRAFIRA_BYTECODE_TEST_ROOT")) warn("cache compile rejected: ", sprintf("%J", { rc, size: length(code), magic: substr(code || "",0,4), source_changed: bounded(source,MAX_FILE)!=text }), "\n");
        erase(base);
        return null;
    }
    // Publish only under the nonblocking cache lock; keep an exact corruption proof.
    if (fs.writefile(base + ".proof", code) != length(code) ||
        !fs.rename(base + ".part", base + ".ucb") || fs.writefile(base + ".json", stamp) != length(stamp)) {
        erase(base);
        return null;
    }
    return base + ".ucb";
}
function run(lib, relative, args) {
    if (index(ALLOWED, relative) < 0) return null;
    let c, entry, locked = false;
    try {
        c = context();
        if (c == null || !lock(c)) return null;
        locked = true;
        entry = prepare(c, lib, relative, lib + "/" + relative);
    } catch (e) {
        if (getenv("TRAFIRA_BYTECODE_TEST_ROOT")) warn("bytecode-cache: ", e, "\n");
        entry = null;
    }
    if (entry == null) {
        if (locked) unlock(c.root);
        return null;
    }
    // Once execution begins, a failing application must never be retried.
    let result = 1;
    try { result = status(system(command([ "/proc/" + fs.readlink("/proc/self") + "/exe", "-L", lib, entry, ...args ]))); } catch (e) { result = 1; }
    unlock(c.root);
    return result;
}
return { run };
