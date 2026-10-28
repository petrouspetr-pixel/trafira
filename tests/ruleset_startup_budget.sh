#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT_DIR/tests/ruleset_startup_budget.cjs"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export STARTUP_BUDGET_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
set -eu
limit=0
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-time) limit="$2"; shift ;;
    --output) out="$2"; shift ;;
    --proxy) echo 'unexpected direct fallback' >&2; exit 97 ;;
  esac
  shift
done
printf '%s\n' "$limit" >>"$STARTUP_BUDGET_TEST/requests"
if [ "$limit" -lt 11 ]; then sleep "$limit"; exit 28; fi
sleep 11
printf 'valid-rules' >"$out"
SH
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
[ "$1" = rule-set ] || exit 1
grep -q valid-rules "$3" || exit 1
cp "$3" "$5"
SH
chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/sing-box"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/check.uc" <<'UC'
let fs=require("fs"),b=require("singbox.ruleset_bootstrap"),root=getenv("STARTUP_BUDGET_TEST");
let path=root+"/config.json",c={route:{rule_set:[{type:"remote",tag:"required",format:"source",url:"https://example.invalid/list",http_client:{}}]}};
fs.writefile(path,sprintf("%J",c));
let ok=b.prepare_file(path,"1.14.3");
assert(ok==(ARGV[0]=="success"),"supervised slow download result");
if(ok) assert(json(fs.readfile(path)).route.rule_set[0].initial_path!=null,"only validated snapshot enables startup");
else assert(fs.readfile(path)==sprintf("%J",c),"failed preparation preserves configuration");
UC
: >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc" failure
printf 'trafira.settings.ruleset_startup_timeout=30\ntrafira.settings.ruleset_download_timeout=15\n' >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc" success
[ "$(tail -n1 "$WORK_DIR/requests")" = 15 ]
rm -rf "$TRAFIRA_RULESET_CACHE_DIR"
TRAFIRA_BOOTSTRAP_TEST_BUDGET=2 ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc" failure
printf 'trafira.settings.ruleset_download_timeout=bad\n' >"$TRAFIRA_UCI_STATE_FILE"
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/check.uc" failure 2>"$WORK_DIR/error"
grep -Fq 'settings.ruleset_download_timeout' "$WORK_DIR/error"
printf 'Supervised slow startup deadline checks passed\n'
