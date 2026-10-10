// Conservative, read-only interpretation of sing-box's ordered routing rules.
// Missing input and unsupported semantics are unknown, never a negative match.
let ip = require("core.ip");
let common = require("core.common");
let arr = common.array_or_empty;
let obj = common.object_or_empty;
function values(value) { return type(value) == "array" ? value : [ value ]; }
function result(value, missing) { return { value, missing: missing ? [missing] : [] }; }
function join_results(items, mode) {
    let missing = [];
    for (let item in items) {
        if (mode == "and" && item.value == "no") return result("no");
        if (mode == "or" && item.value == "yes") return result("yes");
        for (let name in arr(item.missing))
            if (index(missing, name) < 0) push(missing, name);
    }
    return { value: length(missing) ? "unknown" : (mode == "and" ? "yes" : "no"), missing };
}
function domain(value) { return replace(lc(common.as_string(value)), /[.]$/, ""); }
function suffix_matches(name, suffix) {
    name = domain(name); suffix = domain(suffix);
    if (substr(suffix, 0, 1) == ".")
        return length(name) > length(suffix) && substr(name, -length(suffix)) == suffix;
    return name == suffix || (length(name) > length(suffix) && substr(name, -length(suffix)-1) == "." + suffix);
}
function simple_field(key, expected, request, source_mode) {
    let field = key;
    if (index(["domain_suffix", "domain_keyword", "domain_regex"], key) >= 0) field = "domain";
    if (key == "ip_cidr") field = source_mode ? "source_ip" : "destination_ip";
    if (key == "source_ip_cidr") field = "source_ip";
    if (key == "port_range") field = "port";
    if (key == "source_port_range") field = "source_port";
    if (key == "ip_version") {
        let address = request.destination_ip || request.source_ip;
        let version = request.ip_version || (address ? ip.ip_family(address) : null);
        if (version == null) return result("unknown", "ip_version");
        return result(index(values(expected), version) >= 0 ? "yes" : "no");
    }
    if (index(["domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "source_ip_cidr",
               "port", "port_range", "source_port", "source_port_range", "inbound", "network", "protocol",
               "query_type", "clash_mode", "source_mac_address", "source_hostname"], key) < 0)
        return result("unknown", "unsupported:" + key);
    let actual = request[field];
    if (actual == null || actual == "") return result("unknown", field);
    let candidates = [];
    for (let candidate in values(expected)) {
        let matches = false;
        if (key == "domain") matches = domain(actual) == domain(candidate);
        else if (key == "domain_suffix") matches = suffix_matches(actual, candidate);
        else if (key == "domain_keyword") matches = index(domain(actual), domain(candidate)) >= 0;
        else if (key == "domain_regex") {
            // Go RE2 and libc regex differ. Only the common basic subset is evaluated.
            if (type(candidate) != "string" || length(candidate) > 512 ||
                index(candidate, "(?") >= 0 || index(candidate, "\\") >= 0 || index(candidate, "{") >= 0) {
                push(candidates, result("unknown", "unsupported:domain_regex")); continue;
            }
            try { matches = match(domain(actual), regexp(candidate)) != null; }
            catch (e) { push(candidates, result("unknown", "invalid:domain_regex")); continue; }
        }
        else if (key == "ip_cidr" || key == "source_ip_cidr") {
            if (!ip.valid_ip_or_cidr(candidate)) { push(candidates, result("unknown", "invalid:" + key)); continue; }
            matches = ip.ip_in_cidr(actual, candidate);
        }
        else if (key == "port_range" || key == "source_port_range") {
            let bounds = match(common.as_string(candidate), /^([0-9]*):([0-9]*)$/);
            if (!bounds) { push(candidates, result("unknown", "invalid:" + key)); continue; }
            matches = int(actual) >= (bounds[1] == "" ? 0 : int(bounds[1])) &&
                      int(actual) <= (bounds[2] == "" ? 65535 : int(bounds[2]));
        }
        else matches = candidate == actual;
        push(candidates, result(matches ? "yes" : "no"));
    }
    return join_results(candidates, "or");
}
function evaluate(rule, request, rulesets, budget, depth, source_mode) {
    if (depth > 32 || ++budget.steps > 20000) return result("unknown", "evaluation_limit");
    if (type(rule) != "object") return result("unknown", "invalid_rule");
    let clauses = [];
    if (rule.type == "logical") {
        if (index(["and", "or"], rule.mode) < 0 || !length(arr(rule.rules)))
            return result("unknown", "invalid_logical_rule");
        let children = [];
        for (let child in rule.rules) push(children, evaluate(child, request, rulesets, budget, depth+1, source_mode));
        push(clauses, join_results(children, rule.mode));
    }
    else if (rule.type != null && rule.type != "default")
        return result("unknown", "unsupported_rule_type");
    let groups = { destination:[], source:[], port:[], source_port:[] };
    let ignored = ["type", "mode", "rules", "invert", "action", "outbound", "server", "timeout",
        "sniffer", "override_address", "override_port", "strategy", "disable_cache", "rewrite_ttl",
        "reject", "method", "no_drop", "rule_set_ip_cidr_match_source", "rule_set_ipcidr_match_source"];
    for (let key, expected in rule) {
        if (index(ignored, key) >= 0) continue;
        if (key == "rule_set") {
            let matches = [];
            for (let tag in values(expected)) {
                let set = obj(rulesets)[tag];
                if (type(set) != "object" || type(set.rules) != "array") {
                    push(matches, result("unknown", "rule_set:" + common.as_string(tag))); continue;
                }
                let children = [];
                for (let child in set.rules) push(children, evaluate(child, request, rulesets, budget, depth+1,
                    rule.rule_set_ip_cidr_match_source == true || rule.rule_set_ipcidr_match_source == true));
                push(matches, join_results(children, "or"));
            }
            push(clauses, join_results(matches, "or")); continue;
        }
        let item = simple_field(key, expected, request, source_mode);
        if (index(["domain", "domain_suffix", "domain_keyword", "domain_regex", "geosite", "geoip", "ip_cidr", "ip_is_private"], key) >= 0)
            push(groups.destination, item);
        else if (index(["source_geoip", "source_ip_cidr", "source_ip_is_private"], key) >= 0) push(groups.source, item);
        else if (key == "port" || key == "port_range") push(groups.port, item);
        else if (key == "source_port" || key == "source_port_range") push(groups.source_port, item);
        else push(clauses, item);
    }
    for (let key, group in groups)
        if (length(group)) push(clauses, join_results(group, "or"));
    let answer = join_results(clauses, "and");
    if (rule.invert && answer.value != "unknown") answer.value = answer.value == "yes" ? "no" : "yes";
    return answer;
}
function match_rule(rule, request, rulesets) {
    return evaluate(rule, obj(request), obj(rulesets), {steps:0}, 0, false);
}
function explain(config, request, sources, rulesets) {
    let route = obj(obj(config).route), trace = [], budget = {steps:0};
    let current = json(sprintf("%J", obj(request))), selected = null;
    for (let i=0; i<length(arr(route.rules)); i++) {
        let rule = route.rules[i], action = rule.action || (rule.outbound || rule.server ? "route" : "unknown");
        let matched = evaluate(rule, current, rulesets, budget, 0, false);
        let row = {index:i,match:matched.value,action,origin:arr(obj(sources).route)[i] || null,
                   shadowed:selected != null,missing:matched.missing};
        if (length(trace) < 200) push(trace,row);
        if (selected != null || matched.value == "no") continue;
        if (action == "sniff") continue;
        if (matched.value == "unknown") return {status:"indeterminate",rule_index:i,trace,missing:matched.missing};
        if (action == "resolve") {
            // A user-supplied real address is an explicit scenario, not a live DNS answer.
            continue;
        }
        if (action == "route-options") {
            if (rule.override_port != null) current.port = rule.override_port;
            if (rule.override_address != null) {
                if (ip.valid_ip(rule.override_address)) { current.destination_ip = rule.override_address; delete current.domain; }
                else { current.domain = rule.override_address; delete current.destination_ip; }
            }
            continue;
        }
        if (action == "reject") selected = {status:"blocked",rule_index:i};
        else if (action == "route" && (rule.outbound || rule.server)) selected = {status:"matched",rule_index:i,outbound:rule.outbound || rule.server};
        else if (action == "hijack-dns") selected = {status:"matched",rule_index:i,outbound:"dns"};
        else return {status:"indeterminate",rule_index:i,trace,missing:["unsupported_action:" + action]};
    }
    if (!selected) selected = route.final ? {status:route.final == "direct-out" || route.final == "bypass-out" ? "direct" : "matched",outbound:route.final,rule_index:null}
        : {status:"indeterminate",missing:["default_outbound_unknown"],rule_index:null};
    selected.trace = trace;
    selected.trace_truncated = length(arr(route.rules)) > length(trace);
    selected.missing = selected.missing || [];
    return selected;
}
return {match_rule,explain};
