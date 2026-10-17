#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
python3 - "$WORK_DIR" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
base={"settings":{},"section":[{".name":"vpn","enabled":"1","action":"connection","community_lists":["meta"],"ip_cidr":["192.0.2.0/24"]}]}
for name,platforms in [('base',[]),('one',['steam']),('two',['steam','epic'])]:
    doc=json.loads(json.dumps(base))
    for platform in platforms:
        doc['section'] += [{'.name':'game_'+platform+'_store','enabled':'1','action':'connection','domain_suffix':['store.'+platform+'.com']},
                           {'.name':'game_'+platform+'_direct','enabled':'1','action':'bypass','fully_routed_ips':['192.168.10.234/32']}]
    (p/(name+'.json')).write_text(json.dumps(doc))
changed=json.loads(json.dumps(base));changed['section'][0]['ip_cidr']=['198.51.100.0/24']
(p/'inline.json').write_text(json.dumps(changed))
changed=json.loads(json.dumps(base));changed['section'][0]['community_lists']=['telegram']
(p/'source.json').write_text(json.dumps(changed))
PY
signature(){ ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/state.uc" "$1-signature-fixture" "$WORK_DIR/$2.json"; }
base=$(signature list-update base)
for name in one two; do
  test "$(signature list-update "$name")" = "$base" || { echo 'Local gaming rules must not invalidate remote lists'; exit 1; }
  test "$(signature cron "$name")" = "$(signature cron base)" || { echo 'Local gaming rules must not rebuild schedules'; exit 1; }
done
test "$(signature list-update source)" != "$base"
# Mixed inline/remote sets cannot be retained after an inline destination edit.
test "$(signature list-update inline)" != "$base"
echo 'Local presets preserve remote-list identity; changed sources and inline destinations invalidate it'
