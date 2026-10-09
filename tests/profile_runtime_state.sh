#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$WORK_DIR/lib"
export PROFILE_STATE_TEST="$WORK_DIR"
export TRAFIRA_SERVICE_INIT="$WORK_DIR/init"
mkdir -p "$TRAFIRA_LIB/service" "$TRAFIRA_LIB/config" "$TRAFIRA_LIB/singbox"
cat >"$TRAFIRA_LIB/service/state.uc" <<'UC'
// Runtime is present but incomplete nft state makes the health check fail.
exit(ARGV[0]=="sing-box-service-running"?0:1);
UC
printf '#!/bin/sh\nexit 0\n' >"$TRAFIRA_SERVICE_INIT"
chmod +x "$TRAFIRA_SERVICE_INIT"
cat >"$TRAFIRA_LIB/config/validator.uc" <<'UC'
exit(0);
UC
cat >"$TRAFIRA_LIB/singbox/runtime.uc" <<'UC'
print(ARGV[0]=="version"?"1.14.0":ARGV[0]=="variant"?"standard":"127.0.0.1");
UC
cat >"$TRAFIRA_LIB/singbox/generator.uc" <<'UC'
let fs=require("fs");
fs.writefile(getenv("PROFILE_STATE_TEST")+"/mwan",ARGV[4]);
fs.writefile(ARGV[2],"{}");
UC
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/sing-box"
chmod +x "$WORK_DIR/bin/sing-box"
export PATH="$WORK_DIR/bin:$PATH"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),r=require("config.profile_runtime");
let doc={schema:1,name:"State",config:[{".name":"settings",".type":"settings"}]};
let dir=getenv("PROFILE_STATE_TEST")+"/candidate",prepared=r.prepare(doc,dir),hooks=r.hooks(doc,dir);
assert(hooks.capture().running,"a degraded running service must not be treated as stopped");
assert(hooks.validate(prepared.path),"candidate preflight");
assert(fs.readfile(getenv("PROFILE_STATE_TEST")+"/mwan")=="1","preflight uses actual mwan3 state");
'
printf 'profile runtime state checks passed\n'
