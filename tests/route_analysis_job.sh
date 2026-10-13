#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_CONFIG_FILE="$WORK_DIR/uci"
export REAL_UCODE="$(command -v ucode)"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in *service/state.uc*sing-box-service-running*) exit 0;; esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = rule-set ] && [ "$4" = -o ] || exit 1
printf 'codec\n' >>"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls"
sleep 0.15
cp "$3" "$5"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf network >"$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
exit 91
SH
chmod +x "$WORK_DIR/bin/"*
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],sets=[];
for(let i=0;i<45;i++){
 const path=`${dir}/set-${i}.json`;
 fs.writeFileSync(path,JSON.stringify({version:3,rules:[{domain:i===44?'target.example':`other-${i}.example`}]}));
 sets.push({tag:`set-${i}`,type:'local',format:'source',path});
}
fs.writeFileSync(`${dir}/config.json`,JSON.stringify({inbounds:[{tag:'tproxy-in'},{tag:'dns-in'}],route:{rule_set:sets,rules:[{rule_set:sets.map(s=>s.tag),outbound:'vpn-out'}],final:'direct-out'},dns:{rules:[],final:'dns-server'},outbounds:[]}));
JS
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$WORK_DIR/uci"
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config"),u=require("core.uci");assert(a.save(a.capture(u.get_all("trafira","settings"),[])),"checkpoint");'
request='{"domain":"target.example","source":{"kind":"device","ip":"192.0.2.5"},"destination_ip":"203.0.113.10","port":443,"network":"tcp","protocol":"tls"}'
run(){ ucode -L "$TRAFIRA_LIB" "$ROOT_DIR/trafira/files/usr/bin/trafira" "$@"; }
start(){
 run route_explain_start "$request" >"$WORK_DIR/start" || true
 node - "$WORK_DIR/start" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),text=fs.readFileSync(process.argv[2],'utf8');
assert(text.trim().startsWith('{'),'background route API must return JSON');
const r=JSON.parse(text);assert(r.success&&r.running&&/^r-[a-f0-9-]+$/.test(r.job_id),'background route API must start a bounded job: '+JSON.stringify(r));
console.log(r.job_id);
JS
}
finish(){
 local id="$1"
 for n in $(seq 1 180); do
  run route_explain_status "$id" >"$WORK_DIR/status"
  if node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(r.running?1:0)' "$WORK_DIR/status"; then break; fi
  sleep 0.1
 done
 node - "$WORK_DIR/status" <<'JS'
const assert=require('assert/strict'),r=JSON.parse(require('fs').readFileSync(process.argv[2]));
assert(r.success&&!r.running,JSON.stringify(r));assert.equal(r.report.decision.outbound,'vpn-out');assert.equal(r.report.rule_sets.available,45);assert.equal(r.report.rule_sets.unavailable,0);
JS
}
id="$(start)"; finish "$id"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 45
id="$(start)"; finish "$id"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 45
printf '{"version":3,"rules":[{"domain":"new.example"}]}' >"$WORK_DIR/set-0.json"
id="$(start)"; finish "$id"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 46
# Changing the installed codec invalidates all entries, even for identical lists.
printf '\n# replacement codec\n' >>"$WORK_DIR/bin/sing-box"
id="$(start)"; finish "$id"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 91
# Corrupt a cached export: it is rebuilt rather than used as a negative match.
first_cache="$(ls -t "$TRAFIRA_RUNTIME_STATE_DIR/route-decode-cache/"*.json | sed -n '1p')"
printf '{"schema":1,"data":{"rules":[]}}' >"$first_cache"
id="$(start)"; finish "$id"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = 92
run route_explain_status '../escape'  >"$WORK_DIR/invalid" || true
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.success)throw Error("accepted path traversal");' "$WORK_DIR/invalid"
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
# Refuse a verified cache entry before parsing when its budget is exhausted.
ucode -L "$TRAFIRA_LIB" -e 'let c=require("diagnostics.route_decode_cache"),f=require("fs"),root=getenv("TRAFIRA_RUNTIME_STATE_DIR")+"/route-decode-cache";let name=filter(f.lsdir(root),(n)=>match(n,/^[a-f0-9]{64}[.]json$/))[0];assert(c.get(substr(name,0,64),1).error=="size_limit","budget before parse");'
# Refuse a cache directory replaced by a symlink without touching its target.
mkdir "$WORK_DIR/symlink-runtime"
ln -s "$TRAFIRA_RUNTIME_STATE_DIR/route-decode-cache" "$WORK_DIR/symlink-runtime/route-decode-cache"
TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/symlink-runtime" ucode -L "$TRAFIRA_LIB" -e 'let c=require("diagnostics.route_decode_cache");assert(c.get("a",1024)==null,"symlink cache rejected");assert(!c.put("a",{rules:[]},ARGV[0]),"symlink publication rejected");' "$WORK_DIR"
# Source data over the remaining budget never invokes the codec.
before="$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")"
ucode -L "$TRAFIRA_LIB" -e 'let c=require("diagnostics.route_decode_cache");assert(c.decode(ARGV[0],"source",1000,1,ARGV[1]).error=="size_limit","budget before codec");' "$WORK_DIR/set-0.json" "$WORK_DIR"
test "$(wc -l <"$TRAFIRA_RUNTIME_STATE_DIR/codec-calls")" = "$before"
# A killed calculator must not leave its native child or private export behind.
printf '\n# interrupted codec generation\n' >>"$WORK_DIR/bin/sing-box"
id="$(start)"
jobdir="$TRAFIRA_RUNTIME_STATE_DIR/route-analysis/$id"
for n in $(seq 1 200); do
 [ ! -s "$jobdir/codec.pid" ] || break
 sleep 0.01
done
read -r codec_pid codec_ticks <"$jobdir/codec.pid" || true
calculator="$(awk '{print $4}' "/proc/$codec_pid/stat")"
kill -KILL "$calculator"
for n in $(seq 1 100); do
 run route_explain_status "$id" >"$WORK_DIR/interrupted"
 if node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(r.running?1:0)' "$WORK_DIR/interrupted"; then break; fi
 sleep 0.05
done
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.success||r.error!=="worker_interrupted")throw Error(JSON.stringify(r));' "$WORK_DIR/interrupted"
test ! -e "$jobdir/codec.pid"
test ! -e "$jobdir/decode-output"
test ! -e "$jobdir/cache.stage"
printf 'background route cold/warm/invalidation/budget/interruption checks passed\n'

# Killing the supervisor must not permit the old calculator to coexist with a new one.
id="$(start)"
jobdir="$TRAFIRA_RUNTIME_STATE_DIR/route-analysis/$id"
for n in $(seq 1 200); do
 [ ! -s "$jobdir/calculator.json" ] || break
 sleep 0.01
done
supervisor="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).worker.pid)' "$jobdir/state.json")"
old_calculator="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$jobdir/calculator.json")"
kill -KILL "$supervisor"
sleep 0.1
new_id="$(start)"
finish "$new_id"
if [ -f "/proc/$old_calculator/stat" ]; then
 test "$(awk '{print $3}' "/proc/$old_calculator/stat")" = Z
fi
test ! -e "$jobdir/codec.pid"
test ! -e "$jobdir/decode-output"
test ! -e "$jobdir/calculator.json"
printf 'supervisor interruption cleanup passed\n'
