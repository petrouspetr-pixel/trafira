#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_CONFIG_FILE="$TRAFIRA_UCI_STATE_FILE"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export REAL_UCODE="$(command -v ucode)"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR" "$TRAFIRA_RULESET_CACHE_DIR"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in *service/state.uc*sing-box-service-running*) exit 0;; esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '1' >"$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
echo 'route explanation must not download or query DNS' >&2
exit 91
SH
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
# Stand in for the external binary codec only, not the diagnostic evaluator.
[ "$1" = 'rule-set' ] && [ "$4" = '-o' ] || exit 92
case "$2" in compile|decompile) ;; *) exit 92;; esac
if [ "$2" = decompile ] && [ -e "$TRAFIRA_RUNTIME_STATE_DIR/reject-decode" ]; then exit 1; fi
grep -q '"version":3' "$3" || exit 1
cp "$3" "$5"
if [ -e "$TRAFIRA_RUNTIME_STATE_DIR/change-during-decode" ]; then
    printf '{"version":3,"rules":[{"domain_suffix":"changed.example"}]}' >"$3"
fi
SH
chmod +x "$WORK_DIR/bin/ucode" "$WORK_DIR/bin/nft" "$WORK_DIR/bin/curl" "$WORK_DIR/bin/sing-box"
touch "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/config.json" <<'JSON'
{"inbounds":[{"tag":"dns-in"},{"tag":"tproxy-in"}],"route":{"rule_set":[{"type":"remote","tag":"youtube","url":"https://user:secret@example.org/youtube.json?token=secret","format":"source"}],"rules":[{"rule_set":"youtube","outbound":"vpn-out"}],"final":"direct-out"},"dns":{"rules":[{"inbound":"router-tproxy-in","server":"wrong-server"},{"rule_set":"youtube","server":"fakeip-server"}],"final":"dns-server"},"outbounds":[]}
JSON
snapshot_path() { ucode -L "$TRAFIRA_LIB" -e 'let f=require("fs"),c=json(f.readfile(ARGV[0]));print(require("singbox.ruleset_cache").path(c.route.rule_set[0]));' "$WORK_DIR/config.json"; }
stamp() { ucode -L "$TRAFIRA_LIB" -e 'let a=require("service.applied_config"),u=require("core.uci");assert(a.save(a.capture(u.get_all("trafira","settings"),[])),"applied checkpoint");'; }
run() { ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/route_explain.uc" explain "$1"; }
SOURCE_REQUEST='{"domain":"youtube.com","source":{"kind":"device","ip":"192.0.2.5"},"port":443,"network":"tcp","protocol":"tls"}'
ROUTER_REQUEST='{"domain":"youtube.com","source":{"kind":"router"},"port":443,"network":"tcp","protocol":"tls"}'
saved="$(snapshot_path)"
printf '{"version":3,"rules":[{"domain_suffix":"youtube.com"}]}' >"$saved"
stamp
before="$(sha256sum "$saved" "$WORK_DIR/config.json" "$TRAFIRA_UCI_STATE_FILE")"
run "$SOURCE_REQUEST" >"$WORK_DIR/source.json"
run "$ROUTER_REQUEST" >"$WORK_DIR/router.json"
# LuCI file.exec waits for stdout/stderr EOF, not just the ucode process exit.
# A killed watchdog shell can leave its sleep child holding those RPC streams.
node - "$TRAFIRA_LIB" "$ROUTER_REQUEST" <<'JS'
const {spawn}=require('child_process'),assert=require('assert/strict');
const [lib,request]=process.argv.slice(2);
const child=spawn('ucode',['-L',lib,`${lib}/diagnostics/route_explain.uc`,'explain',request]);
let stdout='';
child.stdout.on('data',data=>stdout+=data);
const deadline=setTimeout(()=>{
 child.kill();
 console.error('route explanation must close its RPC streams after the calculation; a watchdog retained stdout/stderr');
 process.exit(1);
},2500);
child.on('error',error=>{clearTimeout(deadline);throw error;});
child.on('close',code=>{
 clearTimeout(deadline);
 assert.equal(code,0,'route subprocess completed');
 assert.equal(JSON.parse(stdout).success,true,'complete JSON arrived before the pipe deadline');
});
JS
test "$before" = "$(sha256sum "$saved" "$WORK_DIR/config.json" "$TRAFIRA_UCI_STATE_FILE")"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),dir=process.argv[2];
const source=JSON.parse(fs.readFileSync(`${dir}/source.json`)),router=JSON.parse(fs.readFileSync(`${dir}/router.json`));
assert.equal(source.decision.outbound,'vpn-out','saved remote list must be usable for scenario evaluation');
assert.equal(source.dns_policy.outbound,'fakeip-server','DNS uses the same saved domain list');
assert.equal(source.rule_sets.basis,'saved_snapshots');
assert.equal(source.rule_sets.live_verified,false,'saved copies never prove running-core bytes');
assert.equal(source.rule_sets.available,1);
assert.equal(source.rule_sets.unavailable,0);
assert(source.limitations.includes('saved_rule_sets_may_differ_from_running_core'));
assert(!source.limitations.includes('remote_rule_sets_not_exported_by_running_core'));
assert.equal(router.dns_policy.outbound,'fakeip-server','router resolver does not pretend to use opt-in capture inbound');
assert(router.decision.missing.includes('router_destination_address_needed'));
assert(!JSON.stringify(source).includes('secret'),'no URL, path or credentials in diagnostic metadata');
JS
# The identity is derived from the configured URL+format, never just the tag.
node - "$WORK_DIR/config.json" <<'JS'
const fs=require('fs'),p=process.argv[2],c=JSON.parse(fs.readFileSync(p));c.route.rule_set[0].url='https://other.example/youtube.json';fs.writeFileSync(p,JSON.stringify(c));
JS
stamp
run "$SOURCE_REQUEST" >"$WORK_DIR/missing.json"
printf '{"version":3,"rules":"corrupt"}' >"$(snapshot_path)"
run "$SOURCE_REQUEST" >"$WORK_DIR/corrupt.json"
printf '{"version":255,"rules":[{"domain_suffix":"youtube.com"}]}' >"$(snapshot_path)"
run "$SOURCE_REQUEST" >"$WORK_DIR/invalid-version.json"
printf '{"version":3,"rules":[{"domain_suffix":"youtube.com"}]}' >"$(snapshot_path)"
touch "$TRAFIRA_RUNTIME_STATE_DIR/change-during-decode"
run "$SOURCE_REQUEST" >"$WORK_DIR/changed.json"
rm "$TRAFIRA_RUNTIME_STATE_DIR/change-during-decode"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),dir=process.argv[2];
for(const name of ['missing','corrupt','invalid-version','changed']) {
 const r=JSON.parse(fs.readFileSync(`${dir}/${name}.json`));
 assert.equal(r.decision.status,'indeterminate',`${name} snapshot cannot disprove an earlier rule`);
 assert(r.decision.missing.includes('rule_set:youtube'));
 assert.equal(r.rule_sets.available,0);
 assert.equal(r.rule_sets.unavailable,1);
 assert.equal(r.rule_sets.unavailable_reasons[0].tag,'youtube');
 assert.equal(r.rule_sets.unavailable_reasons[0].reason,name==='missing'?'missing':name==='changed'?'changed':'decode_failed');
}
JS
node - "$WORK_DIR/config.json" <<'JS'
const fs=require('fs'),p=process.argv[2],c=JSON.parse(fs.readFileSync(p));c.route.rule_set[0].format='binary';fs.writeFileSync(p,JSON.stringify(c));
JS
printf '{"version":3,"rules":[{"domain_suffix":"youtube.com"}]}' >"$(snapshot_path)"
stamp
run "$SOURCE_REQUEST" >"$WORK_DIR/binary.json"
node -e 'const assert=require("assert/strict"),r=JSON.parse(require("fs").readFileSync(process.argv[1]));assert.equal(r.decision.outbound,"vpn-out","binary snapshot is decoded before matching");assert.equal(r.rule_sets.live_verified,false);' "$WORK_DIR/binary.json"
touch "$TRAFIRA_RUNTIME_STATE_DIR/reject-decode"
run "$SOURCE_REQUEST" >"$WORK_DIR/unsupported.json"
rm "$TRAFIRA_RUNTIME_STATE_DIR/reject-decode"
node -e 'const assert=require("assert/strict"),r=JSON.parse(require("fs").readFileSync(process.argv[1]));assert.equal(r.decision.status,"indeterminate");assert.deepEqual(r.rule_sets.unavailable_reasons,[{tag:"youtube",reason:"decode_failed"}],"existing unsupported binary copy is not reported missing");' "$WORK_DIR/unsupported.json"
# Trusted local configured paths retain sing-box's normal symlink behavior.
ln -s "$(snapshot_path)" "$WORK_DIR/local-link"
node - "$WORK_DIR/config.json" "$WORK_DIR/local-link" <<'JS'
const fs=require('fs'),p=process.argv[2],c=JSON.parse(fs.readFileSync(p));
c.route.rule_set[0]={type:'local',tag:'youtube',format:'binary',path:process.argv[3]};fs.writeFileSync(p,JSON.stringify(c));
JS
stamp
run "$SOURCE_REQUEST" >"$WORK_DIR/local.json"
node -e 'const assert=require("assert/strict"),r=JSON.parse(require("fs").readFileSync(process.argv[1]));assert.equal(r.decision.outbound,"vpn-out","configured local symlink must remain readable");assert.equal(r.rule_sets.basis,"local");' "$WORK_DIR/local.json"
test ! -e "$TRAFIRA_RUNTIME_STATE_DIR/network-attempted"
printf 'route explanation snapshot checks passed\n'
