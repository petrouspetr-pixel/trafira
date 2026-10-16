#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_BOOTSTRAP_TEST_DIR="$WORK_DIR"
ucode -L "$LIB" -e '
let b = require("singbox.ruleset_bootstrap");
let c = {outbounds:[{type:"selector",tag:"download",default:"dead",outbounds:["dead","pool"]},{type:"socks",tag:"dead",server:"192.0.2.1",server_port:1080},{type:"urltest",tag:"pool",outbounds:["good","other"]},{type:"socks",tag:"good",server:"proxy.example",server_port:1080},{type:"socks",tag:"other",server:"192.0.2.3",server_port:1080},{type:"socks",tag:"unrelated",server:"192.0.2.4",server_port:1080}],dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"9.9.9.9",server_port:53}]},route:{default_mark:134217728,rule_set:[{type:"remote",tag:"private",format:"source",url:"https://user:secret@lists.example/private?token=secret",http_client:{detour:"download"}}]}};
let p = b.plan(c);
assert(p.error == null, "selected download graph can bootstrap");
assert(length(p.candidates) == 3, "only selected download members become candidates");
assert(p.candidates[0] == "dead" && p.candidates[1] == "good" && p.candidates[2] == "other", "primary precedes nested alternatives");
let stage = b.stage(c, "good", 4539);
assert(length(stage.inbounds) == 1 && stage.inbounds[0].listen == "127.0.0.1" && stage.inbounds[0].type == "mixed", "only private loopback mixed listener");
assert(stage.experimental == null && stage.endpoints == null && stage.services == null, "no cache, API or endpoint side effects");
assert(length(stage.route.rule_set) == 0 && length(stage.route.rules) == 0 && stage.route.final == "good", "bootstrap has no list dependency");
assert(length(stage.outbounds) == 1 && stage.outbounds[0].tag == "good", "only selected candidate dependency graph");
assert(length(stage.dns.servers) == 1 && stage.dns.servers[0].server == "9.9.9.9", "independent configured bootstrap resolver");
assert(stage.route.default_domain_resolver == "bootstrap-dns-server", "proxy hostname resolves without main DNS dependency");
assert(b.prepare({route:{rule_set:[]}}, "1.14.1"), "no lists needs no bootstrap");
c.outbounds[0].outbounds = ["missing"];
assert(b.plan(c).error != null, "missing selected member fails closed");
print("rule-set bootstrap graph checks passed\n");
'
