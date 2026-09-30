#!/usr/bin/env bash
set -eo pipefail
trap 'printf "FAIL: generator list replacement at line %s\n" "$LINENO" >&2' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
GENERATOR="${TRAFIRA_GENERATOR:-$LIB/singbox/generator.uc}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/config.json.rulesets"
printf 'old.example\n203.0.113.0/24\n' >"$WORK_DIR/local.txt"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2];
const fixture={settings:{dns_server:'1.1.1.1'},section:[{'.name':'blocked','.type':'section',enabled:'1',action:'block',domain_ip_lists:[`${dir}/local.txt`]}]};
fs.writeFileSync(`${dir}/fixture.json`,JSON.stringify(fixture));
JS
generate() {
  ucode -L "$LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1 0 1 '' 1.14.1
}
generate
ruleset="$(node -e 'const c=require(process.argv[1]);console.log(c.route.rule_set.find(s=>s.type==="local").path)' "$WORK_DIR/config.json")"
cp "$ruleset" "$WORK_DIR/previous.json"
rm "$WORK_DIR/local.txt"
generate
cmp "$ruleset" "$WORK_DIR/previous.json" || { echo 'FAIL: missing local source destroyed prior materialized list' >&2; exit 1; }
printf 'new.example\n' >"$WORK_DIR/local.txt"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],file=`${dir}/fixture.json`,fixture=JSON.parse(fs.readFileSync(file));
fixture.section[0].domain_ip_lists.push('https://example.com/remote.txt');
fs.writeFileSync(file,JSON.stringify(fixture));
JS
generate
cmp "$ruleset" "$WORK_DIR/previous.json" || { echo 'FAIL: local rebuild erased entries belonging to remote sources' >&2; exit 1; }
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],file=`${dir}/fixture.json`,fixture=JSON.parse(fs.readFileSync(file));
fixture.section[0].domain_ip_lists=[`${dir}/local.txt`];
fs.writeFileSync(file,JSON.stringify(fixture));
JS
generate
node - "$ruleset" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),text=fs.readFileSync(process.argv[2],'utf8');
assert(text.includes('new.example'));assert(!text.includes('old.example'),'successful replacement removes stale entries');
JS
cp "$ruleset" "$WORK_DIR/previous.json"
printf '<html>download failed</html>\n' >"$WORK_DIR/invalid.txt"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'),dir=process.argv[2],file=`${dir}/fixture.json`,fixture=JSON.parse(fs.readFileSync(file));
fixture.section[0].domain_ip_lists.push(`${dir}/invalid.txt`);
fs.writeFileSync(file,JSON.stringify(fixture));
JS
generate
cmp "$ruleset" "$WORK_DIR/previous.json" || { echo 'FAIL: invalid later source published a partial replacement' >&2; exit 1; }
rm "$WORK_DIR/local.txt" "$ruleset"
if generate; then echo 'FAIL: missing first-start list must fail clearly' >&2; exit 1; fi
printf 'generator list replacement checks passed\n'
