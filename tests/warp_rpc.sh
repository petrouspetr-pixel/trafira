#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TRAFIRA_WARP_CLI="$WORK/cli" RPC_LOG="$WORK/calls"
cat >"$TRAFIRA_WARP_CLI" <<'SH'
#!/bin/sh
printf '%s\n' "$2" >>"$RPC_LOG"
printf '%s\n' '{"success":true,"running":true,"private_key":"SECRET","token":"SECRET","endpoint":"162.159.192.1:2408","job":{"job_id":"w-fixture","private_key":"SECRET"},"test":{"summary":{"samples":2,"median":100,"token":"SECRET","services":{"chatgpt":{"dns_errors":1,"connection_errors":2,"http_errors":3,"token":"SECRET"},"arbitrary":{"token":"SECRET"}}}},"changes":[{"section":"cfwarp","change":"added","before":"SECRET"}]}'
SH
chmod +x "$TRAFIRA_WARP_CLI"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/share/rpcd/ucode" -e '
let fs=require("fs"),rpc=require("trafira_warp")["luci.trafira_warp"];
assert(length(keys(rpc))==3 && !rpc.register,"read methods cannot mutate");
let status=rpc.status.call();
assert(status.running && status.job.job_id=="w-fixture" && status.test.summary.samples==2,"public nested result");
assert(status.test.summary.services.chatgpt.dns_errors==1 && !status.test.summary.services.arbitrary,"bounded per-service RPC report");
assert(index(sprintf("%J",status),"SECRET")<0,"strip all secrets from RPC success");
assert(!rpc.action.call({args:{request:"{"}}).success,"invalid JSON rejected");
assert(!rpc.action.call({args:{request:"{\"action\":\"status\"}"}}).success,"action ACL has explicit allowlist");
print("WARP RPC whitelist checks passed\n");
'
python3 - "$ROOT" <<'PYTEST'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])/'components/warp/luci-app-trafira-warp/root/usr/share'
acl=json.loads((root/'rpcd/acl.d/luci-app-trafira-warp.json').read_text())['luci-app-trafira-warp']
assert set(acl['read'])=={'ubus'} and acl['read']['ubus']['luci.trafira_warp']==['status','job_status']
assert set(acl['write'])=={'ubus'} and acl['write']['ubus']['luci.trafira_warp']==['action']
PYTEST
