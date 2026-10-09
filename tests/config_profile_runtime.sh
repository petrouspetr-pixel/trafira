#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci"
export PROFILE_TEST_DIR="$WORK_DIR"
export PATH="$WORK_DIR/bin:$PATH"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stage" "$TRAFIRA_RUNTIME_STATE_DIR"
printf 'trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n' >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'sing-box version 1.14.0'; exit 0; fi
printf '%s\n' "$*" >>"$PROFILE_TEST_DIR/checks"
[ ! -e "$PROFILE_TEST_DIR/reject-check" ]
SH
chmod +x "$WORK_DIR/bin/sing-box"
ucode -L "$TRAFIRA_LIB" -e '
let fs=require("fs"),r=require("config.profile_runtime"),f=require("config.profile_format");
let directory=getenv("PROFILE_TEST_DIR")+"/stage";
let document={schema:1,name:"Test",config:[
 {".name":"settings",".type":"settings",dns_type:"udp",dns_server:["1.1.1.1"],bootstrap_dns_server:["1.1.1.1"]},
 {".name":"direct",".type":"section",enabled:"1",action:"bypass",domain_suffix:["example.org"]}
]};
let prepared=r.prepare(document,directory);
assert(prepared.success,"prepare isolated candidate");
let hooks=r.hooks(document,directory);
assert(hooks.validate(prepared.path),"candidate generated and checked");
assert(fs.readfile(prepared.path)==f.to_uci(document.config),"candidate preserved");
assert(fs.stat(getenv("PROFILE_TEST_DIR")+"/checks"),"real check command invoked");
fs.writefile(getenv("PROFILE_TEST_DIR")+"/reject-check","1");
assert(!hooks.validate(prepared.path),"core rejection propagates");
fs.unlink(getenv("PROFILE_TEST_DIR")+"/reject-check");
assert(!r.dependencies({outbounds:[{bind_interface:"missing-trafira-test"}]}),"missing interface rejected");
assert(!r.dependencies({dns:{servers:[{tls:{client_key_path:"/missing-trafira-key"}}]}}),"missing key rejected");
assert(r.dependencies({outbounds:[{bind_interface:"lo"}]}),"existing interface accepted");
fs.writefile(prepared.path,"changed");
assert(!hooks.validate(prepared.path),"tampered candidate rejected");
'
test "$(stat -c %a "$WORK_DIR/stage/trafira")" = 600
printf 'profile candidate runtime checks passed\n'
