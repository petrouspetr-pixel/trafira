#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_SECTION_CACHE_DIR="$WORK_DIR"
cat >"$WORK_DIR/demo.json" <<'JSON'
{"urltestCandidateTags":["a","b","c"],"links":{"a":"vless://secret"},"outboundMetadata":{"names":{"a":"Alpha","b":"Beta","c":"Gamma"},"countries":{"a":"DE","b":"US","c":"DE"},"protocols":{"a":"vless","b":"trojan","c":"vless"},"transports":{"a":"tcp","b":"ws","c":"ws"},"securities":{"a":"reality","b":"tls","c":"tls"}}}
JSON
python3 - "$WORK_DIR/demo.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['filterPreviewCandidates']={'tags':d['urltestCandidateTags'],'metadata':d['outboundMetadata']}
with open(p,'w') as f: json.dump(d,f)
PY
preview() { ucode -L "$LIB" "$LIB/subscription/preview.uc" preview "$1"; }
check() {
  local request="$1" expected="$2"
  preview "$request" >"$WORK_DIR/result"
  python3 - "$WORK_DIR/result" "$expected" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['status']=='ok',r
assert [n['name'] for n in r['nodes'] if n['status']=='included']==json.loads(sys.argv[2]),r
assert r['counts']['total']==3,r
assert 'secret' not in json.dumps(r) and 'links' not in r,r
PY
}
check '{"section":"demo","filter_mode":"disabled"}' '["Alpha","Beta","Gamma"]'
check '{"section":"demo","filter_mode":"include","include":{"countries":["DE"]}}' '["Alpha","Gamma"]'
check '{"section":"demo","filter_mode":"exclude","exclude":{"outbounds":["Beta"]}}' '["Alpha","Gamma"]'
check '{"section":"demo","filter_mode":"mixed","include":{"regex":["a$"]},"exclude":{"outbounds":["Gamma"]}}' '["Alpha","Beta"]'
check '{"section":"demo","filter_mode":"include","include":{"proxy_parameters":true,"protocols":["vless"],"transports":["tcp"],"securities":["reality"]}}' '["Alpha"]'
check '{"section":"demo","filter_mode":"exclude","exclude":{"proxy_parameters":true,"protocols":["trojan"],"transports":["tcp"]}}' '["Gamma"]'
check '{"section":"demo","filter_mode":"include","include":{"regex":["["]}}' '[]'
for request in '{' '{"section":"../demo"}' '{"section":"demo","include":{"regex":"bad"}}'; do
  preview "$request" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="invalid"'
done
preview '{"section":"absent"}' | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="unavailable"'
preview '{"section":"demo","filter_mode":"include","include":{"regex":["["]}}' | python3 -c 'import json,sys; assert "invalid_regex_ignored" in json.load(sys.stdin)["warnings"]'
preview "$(python3 -c 'print(" "*32769)')" | python3 -c 'import json,sys; assert json.load(sys.stdin)["reason"]=="request_too_large"'
printf '{' >"$WORK_DIR/broken.json"
preview '{"section":"broken"}' | python3 -c 'import json,sys; assert json.load(sys.stdin)["reason"]=="cache_invalid"'
printf '{"urltestCandidateTags":[],"outboundMetadata":{}}' >"$WORK_DIR/legacy.json"
preview '{"section":"legacy"}' | python3 -c 'import json,sys; assert json.load(sys.stdin)["reason"]=="preview_cache_missing"'
python3 - "$WORK_DIR/demo.json" "$WORK_DIR/nocountries.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d['filterPreviewCandidates']['metadata']['countries']={}
with open(sys.argv[2],'w') as f: json.dump(d,f)
PY
preview '{"section":"nocountries","filter_mode":"include","detect_server_country":"country_is","include":{"countries":["DE"]}}' | python3 -c 'import json,sys; assert json.load(sys.stdin)["reason"]=="cached_country_data_incomplete"'
preview '{"section":"nocountries","filter_mode":"include","detect_server_country":"country_is","include":{"regex":["Alpha"]}}' | python3 -c 'import json,sys; assert json.load(sys.stdin)["counts"]["included"]==1'
# Regression: pruning the runtime excludes Beta, but unsaved disabled filters
# must still recover Beta from the independently copied candidate metadata.
mkdir -p "$WORK_DIR/subscriptions"
python3 - "$WORK_DIR/generator.json" "$WORK_DIR/subscriptions/demo-subscription-1.json" <<'PY'
import json,sys
nodes=[{'type':'vless','tag':name,'server':name.lower()+'.example','server_port':443,'uuid':'00000000-0000-4000-8000-000000000001'} for name in ['Alpha','Beta']]
d={'settings':{'.name':'settings','.type':'settings','dns_server':['77.88.8.8'],'bootstrap_dns_server':['77.88.8.8']},'section':[{'.name':'demo','.type':'section','enabled':'1','action':'connection','subscription_urls':['https://subscription.example/test'],'dashboard_filter_mode':'exclude','dashboard_exclude_outbounds':['Beta']}]}
with open(sys.argv[1],'w') as f: json.dump(d,f)
with open(sys.argv[2],'w') as f: json.dump({'outbounds':nodes},f)
PY
printf '%s\n' 'https://subscription.example/test' >"$WORK_DIR/subscriptions/demo-subscription-1.url"
: >"$WORK_DIR/subscriptions/demo-subscription-1.user_agent"
mkdir -p "$WORK_DIR/generated.json.section-cache"
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/generator.json" "$WORK_DIR/generated.json" "127.0.0.1"
TRAFIRA_SECTION_CACHE_DIR="$WORK_DIR/generated.json.section-cache" preview '{"section":"demo","filter_mode":"disabled"}' >"$WORK_DIR/generated-preview.json"
python3 - "$WORK_DIR/generated.json" "$WORK_DIR/generated.json.section-cache/demo.json" "$WORK_DIR/generated-preview.json" <<'PY'
import json,sys
config,cache,preview=[json.load(open(p)) for p in sys.argv[1:]]
assert not any(n.get('server')=='beta.example' for n in config['outbounds']),config
assert 'Beta' not in cache['outboundMetadata']['names'].values(),cache
assert set(cache['filterPreviewCandidates']['metadata'])=={'names','countries','protocols','transports','securities'}
assert [n['name'] for n in preview['nodes'] if n['status']=='included']==['Alpha','Beta'],preview
PY
printf 'subscription preview tests passed\n'
