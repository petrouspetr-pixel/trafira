// Prepare only missing remote-list snapshots before the main core can start.
let fs = require("fs");
let common = require("core.common");
let cache = require("singbox.ruleset_cache");
let identity = require("service.operation_lock").identity;
const LIB = getenv("TRAFIRA_LIB") || "/usr/lib/trafira";
const MAX_FILE = 4194304;
const BUDGET = min(90, max(1, int(getenv("TRAFIRA_BOOTSTRAP_TEST_BUDGET") || "90")));
const MAX_CANDIDATES = min(8, max(1, int(getenv("TRAFIRA_BOOTSTRAP_TEST_MAX_CANDIDATES") || "8")));
function quote(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function run(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function output(args) {
    let stream = fs.popen(command(args), "re");
    if (!stream) return "";
    let raw = stream.read("all");
    return stream.close() == 0 ? trim(raw || "") : "";
}
function copy(value) { return json(sprintf("%J", value)); }
function modern(version) {
    let parts = match("" + version, /^([0-9]+)[.]([0-9]+)/);
    return parts && (int(parts[1]) > 1 || (int(parts[1]) == 1 && int(parts[2]) >= 14));
}
function index_outbounds(config) {
    let result = {};
    for (let outbound in common.array_or_empty(config.outbounds))
        if (outbound.tag) result[outbound.tag] = outbound;
    return result;
}
function members(outbound) {
    let values = common.array_or_empty(outbound.outbounds), result = [];
    if (outbound.default && index(values, outbound.default) >= 0) push(result, outbound.default);
    for (let tag in values) if (index(result, tag) < 0) push(result, tag);
    return result;
}
function visit(tag, state, depth) {
    if (depth > 32 || state.visiting[tag]) { state.error = "invalid download graph"; return; }
    let outbound = state.index[tag];
    if (!outbound) { state.error = "missing download member or unsupported endpoint"; return; }
    if (outbound.type != "selector" && outbound.type != "urltest") {
        if (index(state.candidates, tag) < 0 && length(state.candidates) < MAX_CANDIDATES)
            push(state.candidates, tag);
        return;
    }
    let list = members(outbound);
    if (length(list) == 0) { state.error = "empty download group"; return; }
    state.visiting[tag] = true;
    for (let member in list) visit(member, state, depth + 1);
    delete state.visiting[tag];
}
function remote_rules(config) {
    return filter(common.array_or_empty(config.route && config.route.rule_set),
        (rule) => rule.type == "remote" && type(rule.http_client) == "object");
}
function plan(config, rule) {
    rule = rule || remote_rules(config)[0];
    if (!rule) return {candidates: []};
    let target = rule.http_client.detour || "";
    // An empty detour means the user explicitly configured direct list downloads.
    if (target == "") return {candidates: [""], target};
    let state = {index: index_outbounds(config), candidates: [], visiting: {}};
    visit(target, state, 0);
    return {candidates: state.candidates, target, error: state.error};
}
function dependency(tag, state, depth) {
    if (depth > 32 || state.visiting[tag]) { state.error = true; return; }
    if (state.added[tag]) return;
    let original = state.index[tag];
    if (!original) { state.error = true; return; }
    let outbound = copy(original);
    state.visiting[tag] = true;
    if (outbound.type == "urltest" || outbound.type == "selector") {
        let ordered = members(outbound);
        if (!length(ordered)) { state.error = true; return; }
        // Dependency groups stay pinned; no active URLTest probes or API mutations.
        outbound = {type:"selector", tag, outbounds:ordered, default:ordered[0]};
        for (let member in ordered) dependency(member, state, depth + 1);
    }
    if (outbound.detour) dependency(outbound.detour, state, depth + 1);
    if (outbound.server || outbound.domain_resolver)
        outbound.domain_resolver = "bootstrap-dns-server";
    delete state.visiting[tag];
    state.added[tag] = true;
    push(state.outbounds, outbound);
}
function stage(config, candidate, port, credentials) {
    let bootstrap;
    for (let server in common.array_or_empty(config.dns && config.dns.servers))
        if (server.tag == "bootstrap-dns-server") bootstrap = copy(server);
    if (!bootstrap || !require("core.ip").valid_ip(bootstrap.server))
        return {error:"independent bootstrap IP resolver required"};
    // Bootstrap lookups use the configured resolver directly, never the main
    // resolver's proxy detour or a listener that has not started yet.
    delete bootstrap.detour;
    delete bootstrap.domain_resolver;
    let state = {index:index_outbounds(config), added:{}, visiting:{}, outbounds:[]};
    dependency(candidate, state, 0);
    if (state.error) return {error:"unsupported outbound dependency"};
    let route = {rules:[], rule_set:[], final:candidate, default_domain_resolver:"bootstrap-dns-server"};
    for (let key in ["default_mark", "default_interface", "auto_detect_interface"])
        if (config.route && config.route[key] != null) route[key] = config.route[key];
    let inbound = {type:"mixed", tag:"ruleset-bootstrap-in", listen:"127.0.0.1", listen_port:port};
    if (credentials) inbound.users = [credentials];
    return {log:{disabled:true}, inbounds:[inbound], outbounds:state.outbounds,
        dns:{servers:[bootstrap], final:"bootstrap-dns-server"}, route};
}
function worker_script() { return "#!/bin/sh\nset -u\ndir=\"$1\"\nowner=\"$2\"\nticks=\"$3\"\nbudget=\"$4\"\nurl=\"$5\"\nauth=\"$6\"\nport=\"$7\"\ncore=\"\"\nfetch=\"\"\nwatch=\"\"\nworker=$$\nidentity() {\n    [ -r \"/proc/$owner/stat\" ] || return 1\n    raw=$(cat \"/proc/$owner/stat\") || return 1\n    rest=${raw##*) }\n    set -- $rest\n    [ \"$1\" != Z ] || return 1\n    shift 19\n    [ \"$1\" = \"$ticks\" ]\n}\ncleanup() {\n    trap - EXIT INT TERM\n    for child in \"$watch\" \"$fetch\" \"$core\"; do\n        [ -z \"$child\" ] || kill -TERM \"$child\" 2>/dev/null || :\n    done\n    sleep 0.1\n    for child in \"$watch\" \"$fetch\" \"$core\"; do\n        [ -z \"$child\" ] || kill -KILL \"$child\" 2>/dev/null || :\n    done\n    wait 2>/dev/null || :\n}\ntrap cleanup EXIT\ntrap 'exit 1' INT TERM\nstart=$(cut -d. -f1 /proc/uptime)\nif [ \"$port\" != \"-\" ]; then\n    sing-box run -c \"$dir/config.json\" </dev/null >/dev/null 2>&1 &\n    core=$!\nfi\n(\n    while :; do\n        now=$(cut -d. -f1 /proc/uptime)\n        if ! identity || [ \"$((now-start))\" -ge \"$budget\" ]; then\n            for child in \"$fetch\" \"$core\"; do\n                [ -z \"$child\" ] || kill -KILL \"$child\" 2>/dev/null || :\n            done\n            if [ -r \"$dir/curl.pid\" ]; then\n                child=$(cat \"$dir/curl.pid\")\n                case \"$child\" in *[!0-9]*|\"\") ;; *) kill -KILL \"$child\" 2>/dev/null || : ;; esac\n            fi\n            kill -TERM \"$worker\" 2>/dev/null || :\n            if ! identity; then\n                sleep 0.2\n                rm -rf \"$dir\"\n            fi\n            exit 0\n        fi\n        sleep 0.1\n    done\n) </dev/null >/dev/null 2>&1 &\nwatch=$!\nif [ \"$port\" != \"-\" ]; then\n    sleep 0.1\n    kill -0 \"$core\" 2>/dev/null || exit 1\n    set -- --proxy \"http://127.0.0.1:$port\" --proxy-user \"$auth\" --noproxy \"\"\nelse\n    set -- --noproxy \"*\"\nfi\ncurl --fail --location --silent --show-error --connect-timeout 3 --max-time \"$budget\" --max-filesize 4194304 --retry 2 --retry-connrefused --retry-delay 1 --retry-max-time 2 --output \"$dir/download\" \"$@\" \"$url\" </dev/null >/dev/null 2>&1 &\nfetch=$!\nprintf '%s' \"$fetch\" >\"$dir/curl.pid\"\nwait \"$fetch\"\nresult=$?\nfetch=\"\"\nexit \"$result\"\n"; }
function cleanup(directory) {
    if (directory && match(directory, /^\/tmp\/trafira-ruleset-bootstrap[.][A-Za-z0-9]+(\/fetch)?$/))
        run(["rm", "-rf", directory]);
}
function fetch(config, rule, candidate, directory, seconds) {
    let owner = identity();
    if (!owner) return false;
    let auth = trim(fs.readfile("/proc/sys/kernel/random/uuid") || "");
    if (!match(auth, /^[a-f0-9-]{36}$/)) return false;
    let port = 20000 + (int(owner.pid) % 30000);
    let file = directory + "/config.json";
    let script = directory + "/fetch.sh";
    let staged = candidate == "" ? null : stage(config, candidate, port, {username:"bootstrap",password:auth});
    if (staged && staged.error) return false;
    fs.unlink(directory + "/download");
    fs.unlink(directory + "/curl.pid");
    if (staged && fs.writefile(file, sprintf("%J", staged)) == null) return false;
    if (fs.writefile(script, worker_script()) == null) return false;
    return run(["sh", script, directory, owner.pid, owner.ticks, seconds,
        rule.url, "bootstrap:" + auth, staged ? "" + port : "-"]);
}
function prepare(config, version, workspace) {
    let rules = remote_rules(config);
    if (!modern(version) || length(rules) == 0) return true;
    let pending = [], seen = {};
    for (let rule in rules) {
        let path = cache.path(rule);
        if (!path) return false;
        if (cache.validate(rule, path)) { rule.initial_path = path; continue; }
        if (!seen[path]) { push(pending, rule); seen[path] = true; }
    }
    if (!length(pending)) return true;
    let directory = workspace ? workspace + "/fetch" : output(["mktemp", "-d", "/tmp/trafira-ruleset-bootstrap.XXXXXX"]);
    if (workspace && !fs.mkdir(directory, 448)) return false;
    if (!directory || !run(["chmod", "700", directory])) return false;
    let deadline = int(clock(true)[0]) + BUDGET, ok = true;
    try {
        let groups = {}, order = [];
        for (let rule in pending) {
            let p = plan(config, rule);
            if (p.error || !length(p.candidates)) { ok = false; break; }
            if (groups[p.target] == null) { groups[p.target] = {rules:[], candidates:p.candidates}; push(order, p.target); }
            push(groups[p.target].rules, rule);
        }
        let tried = 0;
        for (let target in order) {
            let group = groups[target];
            for (let candidate in group.candidates) {
                if (tried++ >= MAX_CANDIDATES || int(clock(true)[0]) >= deadline) break;
                for (let rule in group.rules) {
                    let path = cache.path(rule);
                    if (cache.validate(rule, path)) continue;
                    let remaining = deadline - int(clock(true)[0]);
                    if (remaining <= 0) break;
                    // One failed request is enough to try the next member.
                    // A dead default must not consume the budget once per list.
                    if (!fetch(config, rule, candidate, directory, min(10, remaining))) break;
                    let info = fs.lstat(directory + "/download");
                    if (!info || info.type != "file" || info.size <= 0 || info.size > MAX_FILE ||
                        !cache.save(rule, directory + "/download")) break;
                }
                let complete = true;
                for (let rule in group.rules)
                    if (!cache.validate(rule, cache.path(rule))) complete = false;
                if (complete) break;
            }
        }
        for (let rule in rules) {
            let path = cache.path(rule);
            if (cache.validate(rule, path)) rule.initial_path = path;
            else ok = false;
        }
    } catch (e) { ok = false; }
    cleanup(directory);
    if (!ok) warn("Rule-set startup preparation failed: a validated snapshot is missing and the configured download egress is unavailable\n");
    return ok;
}
function prepare_file_inline(path, version, workspace) {
    let config = common.read_json_file(path);
    // Configuration validation remains the runtime owner's responsibility.
    if (type(config) != "object" || !length(remote_rules(config))) return true;
    if (!prepare(config, version, workspace)) return false;
    return fs.writefile(path, sprintf("%J", config)) != null;
}
function supervise(path, version, directory, owner_pid, owner_ticks) {
    let args = ["ucode", "-L", LIB, LIB + "/singbox/ruleset_bootstrap.uc", "bootstrap-worker", path, version, directory];
    let stream = fs.popen(command(args) + " </dev/null >/dev/null 2>&1 & echo $!", "re");
    let pid = stream ? trim(stream.read(64) || "") : "";
    if (stream) stream.close();
    let worker = match(pid, /^[1-9][0-9]*$/) ? identity(pid) : null;
    let deadline = int(clock(true)[0]) + BUDGET, result = false;
    if (worker) {
        while (int(clock(true)[0]) < deadline) {
            let owner = identity(owner_pid), child = identity(worker.pid);
            if (!owner || owner.ticks != owner_ticks || owner.state == "Z") break;
            let status = fs.readfile(directory + "/result");
            if (status != null) { result = status == "1"; break; }
            if (!child || child.ticks != worker.ticks || child.state == "Z") break;
            system("sleep 0.1");
        }
        // The supervisor outlives a killed runtime caller. Descendants are
        // stopped with PID/start-time checks, including validators and curl.
        let processes = require("diagnostics.route_memory");
        processes.stop(processes.tree(worker, {}));
    }
    cleanup(directory);
    return result;
}
function prepare_file(path, version) {
    let config = common.read_json_file(path);
    if (type(config) != "object" || !modern(version) || !length(remote_rules(config))) return true;
    let all_cached = true;
    for (let rule in remote_rules(config))
        if (!cache.validate(rule, cache.path(rule))) all_cached = false;
    if (all_cached) return prepare_file_inline(path, version);
    let owner = identity(), directory = output(["mktemp", "-d", "/tmp/trafira-ruleset-bootstrap.XXXXXX"]);
    if (!owner || !directory || !run(["chmod", "700", directory])) { cleanup(directory); return false; }
    let ok = run(["ucode", "-L", LIB, LIB + "/singbox/ruleset_bootstrap.uc", "bootstrap-supervise", path, version, directory, owner.pid, owner.ticks]);
    cleanup(directory);
    if (!ok) warn("Rule-set startup preparation failed: required snapshots could not be prepared within the startup budget\n");
    return ok;
}
if (ARGV[0] == "bootstrap-worker") {
    let result = prepare_file_inline(ARGV[1], ARGV[2], ARGV[3]);
    fs.writefile(ARGV[3] + "/result", result ? "1" : "0");
    exit(result ? 0 : 1);
}
if (ARGV[0] == "bootstrap-supervise")
    exit(supervise(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
return {plan, stage, prepare, prepare_file};

