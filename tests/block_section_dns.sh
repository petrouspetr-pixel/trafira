#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${TRAFIRA_TEST_LIB:-$ROOT_DIR/trafira/files/usr/lib}
GENERATOR=${TRAFIRA_GENERATOR:-$LIB/singbox/generator.uc}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/input.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[{".name":"ads",".type":"section","enabled":"1","action":"block","domain_suffix":["ads.example"],"community_lists":["ads_hagezi_pro"]},{".name":"device_ads",".type":"section","enabled":"1","action":"block","domain_suffix":["device.example"],"source_ip_cidr":["192.0.2.7/32"]},{".name":"vpn",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["socks5://127.0.0.1:1080#Test"],"domain_suffix":["example"]}]}
JSON
for version in 1.13.18 1.14.1; do
 ucode -L "$LIB" "$GENERATOR" generate-config-fixture "$WORK_DIR/input.json" "$WORK_DIR/config.json" 127.0.0.1 0 1 '' "$version"
 ucode - "$WORK_DIR/config.json" <<'UC'
let c=json(require("fs").readfile(ARGV[0]));
function check(ok,message) { if (!ok) die(message+"\n"); }
let blocked=filter(c.dns.rules,r=>r.domain_suffix!=null && index(r.domain_suffix,"ads.example")>=0);
check(length(blocked)==1 && blocked[0].action=="predefined" && blocked[0].rcode=="NXDOMAIN","block section must return NXDOMAIN instead of FakeIP");
check(blocked[0].server==null && blocked[0].rewrite_ttl==null,"negative answer must not reference a resolver or route TTL");
let sets=filter(c.dns.rules,r=>r.rule_set!=null && r.action=="predefined");
check(length(sets)==1 && sets[0].rcode=="NXDOMAIN","community ad list must block before FakeIP");
let scoped=filter(c.dns.rules,r=>r.domain_suffix!=null && index(r.domain_suffix,"device.example")>=0);
check(length(scoped)==1 && scoped[0].action=="predefined" && scoped[0].source_ip_cidr=="192.0.2.7/32" && scoped[0].inbound!=null,"device scope must be preserved");
let rejects=filter(c.route.rules,r=>r.action=="reject" && r.rule_set!=null);
check(length(rejects)==1,"cached FakeIP connections must still be rejected");
let vpn=filter(c.dns.rules,r=>r.domain_suffix!=null && index(r.domain_suffix,"example")>=0);
check(length(vpn)==1 && vpn[0].action=="route" && vpn[0].server=="fakeip-server","ordinary routing must retain FakeIP");
UC
done
echo 'block section DNS checks passed'
