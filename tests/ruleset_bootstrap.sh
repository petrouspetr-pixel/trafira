#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export TRAFIRA_BOOTSTRAP_TEST_DIR="$WORK_DIR"
export TRAFIRA_LIB="$LIB"
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

mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
if [ "$1" = rule-set ]; then
  grep -q valid-rules "$3" || exit 1
  cp "$3" "$5"
  exit 0
fi
[ "$1" = run ] || exit 1
cp "$3" "$TRAFIRA_BOOTSTRAP_TEST_DIR/stage.json"
echo "$$" >>"$TRAFIRA_BOOTSTRAP_TEST_DIR/core.pids"
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
set -eu
printf 'attempt\n' >>"$TRAFIRA_BOOTSTRAP_TEST_DIR/attempts"
out=""
proxy=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift ;;
    --proxy) proxy=1; shift ;;
  esac
  shift
done
[ "$proxy" = 1 ] || exit 97
[ ! -f "$TRAFIRA_BOOTSTRAP_TEST_DIR/offline" ] || exit 28
if ! node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.env.TRAFIRA_BOOTSTRAP_TEST_DIR+"/stage.json")).route.final === "good" ? 0 : 1)'; then
  [ ! -f "$TRAFIRA_BOOTSTRAP_TEST_DIR/many" ] || sleep 0.3
  exit 7
fi
if [ -f "$TRAFIRA_BOOTSTRAP_TEST_DIR/stall" ]; then
  echo "$$" >"$TRAFIRA_BOOTSTRAP_TEST_DIR/curl.pid"
  exec sleep 30
fi
printf valid-rules >"$out"
SH
chmod +x "$WORK_DIR/bin/sing-box" "$WORK_DIR/bin/curl"
cat >"$WORK_DIR/prepare.uc" <<'UC'
let fs = require("fs"), b = require("singbox.ruleset_bootstrap"), cache = require("singbox.ruleset_cache");
let root = getenv("TRAFIRA_BOOTSTRAP_TEST_DIR");
let rule = {type:"remote",tag:"test",format:"source",url:"https://user:secret@list.example/test?token=secret",http_client:{detour:"selected"}};
let c = {outbounds:[{type:"selector",tag:"selected",default:"dead",outbounds:["dead","good"]},{type:"socks",tag:"dead",server:"192.0.2.1",server_port:1080},{type:"socks",tag:"good",server:"192.0.2.2",server_port:1080}],dns:{servers:[{type:"udp",tag:"bootstrap-dns-server",server:"9.9.9.9",server_port:53}]},route:{rule_set:[rule]}};
if (ARGV[0] == "many") {
  c.route.rule_set = [];
  for (let i = 0; i < 22; i++) push(c.route.rule_set, {...rule, tag:"list-"+i, url:"https://list.example/"+i});
}
if (ARGV[0] == "offline") fs.writefile(root+"/offline", "1");
if (ARGV[0] == "corrupt") fs.writefile(cache.path(rule), "corrupt");
let through_file = index(["cold-file","offline","timeout","parent-death"],ARGV[0]) >= 0;
let path = root + "/candidate.json";
let provenance = require("singbox.provenance"), store = require("singbox.failure_store");
if (through_file) {
  fs.writefile(path, sprintf("%J", c));
  assert(provenance.save(path,{schema:1,route:[],dns:[]}),"save provenance fixture");
  assert(store.save_base(path,c,[{".name":"protected",action:"connection",failure_policy:"block"}]),"save baseline fixture");
}
let ok = through_file ? b.prepare_file(path, "1.14.1") : b.prepare(c, "1.14.1");
if (ARGV[0] == "many") {
  assert(ok, "dead first candidate must not spend the whole budget on many lists");
  for (let item in c.route.rule_set) assert(cache.validate(item,item.initial_path), "every required list remains nonempty and valid");
  exit(0);
}
if (ARGV[0] == "timeout") {
  assert(!ok, "total startup timeout fails closed");
  assert(fs.readfile(path) == sprintf("%J", c), "failure preserves candidate bytes");
  exit(0);
}
if (ARGV[0] == "offline-missing") assert(!ok, "offline first boot must fail closed");
else if (ARGV[0] == "corrupt") assert(!ok, "corrupt offline snapshot must fail closed");
else {
  assert(ok, "alternate candidate downloads missing rule set");
  if (through_file) {
    assert(provenance.load(path) != null,"startup preparation preserves digest-bound provenance");
    let base = store.load(path);
    assert(base != null && base.sections[0][".name"] == "protected", "startup preparation preserves failure-policy baseline and sections");
    assert(base.config.route.rule_set[0].initial_path == cache.path(rule),"baseline uses the same validated snapshot");
    rule = json(fs.readfile(path)).route.rule_set[0];
  }
  assert(rule.initial_path == cache.path(rule) && cache.validate(rule,rule.initial_path), "validated snapshot used for core startup");
}
UC
ucode -L "$LIB" "$WORK_DIR/prepare.uc" cold-file 2>"$WORK_DIR/log"
[ "$(wc -l <"$WORK_DIR/attempts")" -eq 2 ]
ucode -L "$LIB" "$WORK_DIR/prepare.uc" offline 2>>"$WORK_DIR/log"
[ "$(wc -l <"$WORK_DIR/attempts")" -eq 2 ] || { echo 'cached startup must not download'; exit 1; }
ucode -L "$LIB" "$WORK_DIR/prepare.uc" corrupt 2>>"$WORK_DIR/log"
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
ucode -L "$LIB" "$WORK_DIR/prepare.uc" offline-missing 2>>"$WORK_DIR/log"
if grep -Eq 'secret|user:|https://|list.example' "$WORK_DIR/log"; then
  echo 'bootstrap diagnostics must redact URLs and credentials'
  exit 1
fi
while read -r pid; do
  ! kill -0 "$pid" 2>/dev/null || { echo "bootstrap child remains: $pid"; exit 1; }
done <"$WORK_DIR/core.pids"
rm -f "$WORK_DIR/offline"
touch "$WORK_DIR/stall"
started=$SECONDS
TRAFIRA_BOOTSTRAP_TEST_BUDGET=2 ucode -L "$LIB" "$WORK_DIR/prepare.uc" timeout 2>>"$WORK_DIR/log"
[ "$((SECONDS-started))" -lt 6 ] || { echo 'startup total budget was exceeded'; exit 1; }
rm -f "$WORK_DIR/curl.pid"
TRAFIRA_BOOTSTRAP_TEST_BUDGET=8 ucode -L "$LIB" "$WORK_DIR/prepare.uc" parent-death 2>>"$WORK_DIR/log" &
caller=$!
for _ in $(seq 1 50); do
  [ ! -f "$WORK_DIR/curl.pid" ] || break
  sleep 0.1
done
[ -f "$WORK_DIR/curl.pid" ] || { kill "$caller" || true; echo 'parent-death scenario did not reach curl'; exit 1; }
fetch_pid=$(cat "$WORK_DIR/curl.pid")
core_pid=$(tail -n1 "$WORK_DIR/core.pids")
kill -KILL "$caller"
wait "$caller" 2>/dev/null || true
for _ in $(seq 1 50); do
  running=0
  for pid in "$fetch_pid" "$core_pid"; do
    if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]; then running=1; fi
  done
  [ "$running" -ne 0 ] || break
  sleep 0.1
done
[ "$running" -eq 0 ] || { echo 'bootstrap descendants survived killed owner'; exit 1; }
rm -f "$WORK_DIR/stall"
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
touch "$WORK_DIR/many"
before=$(wc -l <"$WORK_DIR/attempts")
TRAFIRA_BOOTSTRAP_TEST_BUDGET=12 ucode -L "$LIB" "$WORK_DIR/prepare.uc" many 2>>"$WORK_DIR/log"
[ "$(( $(wc -l <"$WORK_DIR/attempts")-before ))" -eq 23 ] || { echo 'dead candidate must fail once before trying the alternate for all lists'; exit 1; }
printf 'rule-set bootstrap download checks passed\n'
