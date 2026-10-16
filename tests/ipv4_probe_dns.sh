#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),root=process.argv[2];
const ui=fs.readFileSync(root+'/luci-app-trafira/htdocs/luci-static/resources/view/trafira/settings.js','utf8');
assert(ui.includes('"disable_ipv6_probes"'),'IPv4 probe filtering must be available in LuCI');
const block=ui.slice(ui.indexOf('"disable_ipv6_probes"'),ui.indexOf('"dns_detour_enabled"'));
assert(block.includes('o.default = "1"'),'LuCI defaults IPv4 probe filtering to enabled');
assert(block.includes('o.rmempty = false'),'explicit disabled choice must persist');
assert(/option disable_ipv6_probes '1'/.test(fs.readFileSync(root+'/trafira/files/etc/config/trafira','utf8')),'fresh config enables the filter');
JS
for mode in ipv4_only prefer_ipv4 ipv6_only prefer_ipv6; do
 for enabled in 0 1 default; do
  printf '{"settings":{"dns_strategy":"%s","disable_ipv6_probes":"%s"},"section":[{".name":"meta",".type":"section","enabled":"1","action":"connection","proxy_config_type":"interface","interface":"awg0","domain_suffix":["fbcdn.net","cloudflare.com"]}]}' "$mode" "$enabled" >"$WORK_DIR/input.json"
  if [ "$enabled" = default ]; then
    node - "$WORK_DIR/input.json" <<'JS'
const fs=require('fs'),p=process.argv[2],data=JSON.parse(fs.readFileSync(p));delete data.settings.disable_ipv6_probes;fs.writeFileSync(p,JSON.stringify(data));
JS
  fi
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/input.json" "$WORK_DIR/$mode-$enabled.json" 127.0.0.1 0 1 '' 1.14.1
 done
done
printf '{"settings":{"dns_strategy":"ipv4_only"},"section":[{".name":"direct_section",".type":"section","enabled":"1","action":"bypass"}]}' >"$WORK_DIR/input.json"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/input.json" "$WORK_DIR/default.json" 127.0.0.1 0 1 '' 1.13.18
printf '{"settings":{"dns_strategy":"ipv4_only","disable_ipv6_probes":"1","alice_mode_enabled":"1","alice_ips":["192.0.2.1/32"]},"section":[{".name":"direct_section",".type":"section","enabled":"1","action":"bypass"}]}' >"$WORK_DIR/input.json"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/input.json" "$WORK_DIR/alice.json" 127.0.0.1 0 1 '' 1.14.1
printf '{"settings":{"dns_strategy":"ipv4_only","disable_ipv6_probes":"1","router_origin_enabled":"1","router_origin_section":"meta"},"server":[{".name":"first",".type":"server","enabled":"1","protocol":"socks","socks_auth_enabled":"0","listen_port":"1080","routing_mode":"section","routing_section":"meta"},{".name":"second",".type":"server","enabled":"1","protocol":"socks","socks_auth_enabled":"0","listen_port":"1081","routing_mode":"section","routing_section":"meta"}],"section":[{".name":"meta",".type":"section","enabled":"1","action":"connection","proxy_config_type":"interface","interface":"awg0","domain_suffix":["fbcdn.net"]}]}' >"$WORK_DIR/input.json"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/input.json" "$WORK_DIR/router.json" 127.0.0.1 0 1 '' 1.14.1
node - "$WORK_DIR" "$ROOT_DIR" <<'JS'
const fs=require('fs'),assert=require('assert/strict'),dir=process.argv[2];
assert(JSON.parse(fs.readFileSync(dir+'/default.json')).dns.rules.some(r=>r.action==='predefined'),'on by default with IPv4 only');
assert(JSON.parse(fs.readFileSync(dir+'/default.json')).route.rules.some(r=>r.domain?.includes('v6.xy.fbcdn.net')),'route filter on by default');
const alice=JSON.parse(fs.readFileSync(dir+'/alice.json')).dns.rules;
const bypass=alice.findIndex(r=>r.inbound==='alice-dns-in'),filterIndex=alice.findIndex(r=>r.action==='predefined');
assert(bypass>=0&&filterIndex>=0&&bypass<filterIndex,'Alice bypass before probe filter');
const router=JSON.parse(fs.readFileSync(dir+'/router.json'));
assert.deepEqual(router.route.rules.slice(0,4).map(r=>r.action),['sniff','sniff','sniff','hijack-dns'],'all listeners must be sniffed and DNS hijacked before filtering');
assert.equal(router.route.rules[4].domain?.[0],'v6.xy.fbcdn.net','probe reject must precede router outbound too');
assert.equal(router.route.rules[5].outbound,'meta-out','router route follows probe rejection');
const sonars=JSON.parse(fs.readFileSync(process.argv[3]+'/tests/fixtures/ipv6_sonar_probe_domains.json'));
assert.equal(sonars.length,95);
const yes=[...sonars,'v6.xy.fbcdn.net','fa4e35f8-5be3-4814-af28-573a3fe281ed-netseer-ipaddr-assoc.xy.fbcdn.net','sonar6.fhrk1-1.fna.fbcdn.net','sonar6.fppk1-1.fna.fbcdn.net','sonar6.frix7-1.fna.fbcdn.net','brunhild.challenges.cloudflare.com'];
const no=['sonar6-ams2-1.xx.fbcdn.net.evil.test','sonar6-ams2-1.xy.fbcdn.net','sonar-ams2-1.xx.fbcdn.net','sonar4-ams2-1.xx.fbcdn.net','sonar6-ams-1.xx.fbcdn.net','sonar6-amsterdam2-1.xx.fbcdn.net','prefix-sonar6-ams2-1.xx.fbcdn.net','fbcdn.net','scontent.xy.fbcdn.net','video.xx.fbcdn.net','challenges.cloudflare.com','other.challenges.cloudflare.com','brunhild.challenges.cloudflare.com.evil.test','v6.xy.fbcdn.net.evil.test','csp.yandex.net','sonar6.unverified.fna.fbcdn.net'];
for(const mode of ['ipv4_only','prefer_ipv4','ipv6_only','prefer_ipv6'])for(const enabled of ['0','1','default']){
 const c=JSON.parse(fs.readFileSync(`${dir}/${mode}-${enabled}.json`));
 const rejects=c.route.rules.filter(r=>r.action==='reject'&&r.domain?.includes('v6.xy.fbcdn.net'));
 const rules=c.dns.rules.filter(r=>r.action==='predefined');
 if(mode!=='ipv4_only'||enabled==='0'){assert.equal(rules.length,0);assert.equal(rejects.length,0);continue;}
 assert.equal(rules.length,1);const rule=rules[0];assert.equal(rule.rcode,'NXDOMAIN');
 const match=domain=>(rule.domain||[]).includes(domain)||(rule.domain_regex||[]).some(re=>new RegExp(re).test(domain));
 for(const name of yes)assert(match(name),'expected '+name);
 for(const name of no)assert(!match(name),'must not block '+name);
 const index=c.dns.rules.indexOf(rule),fake=c.dns.rules.findIndex(r=>r.server==='fakeip-server');
 assert(index>=0&&index<fake,'filter must precede FakeIP');
 assert.equal(rejects.length,1,'IPv4 probe connections must be rejected before AWG');
 const reject=rejects[0];
 assert.deepEqual(reject.domain,rule.domain);
 assert.deepEqual(reject.domain_regex,rule.domain_regex);
 assert.equal(reject.network,undefined,'reject both TCP and UDP');
 assert.equal(c.route.rules[0].action,'sniff');
 assert.equal(c.route.rules[1].action,'hijack-dns');
 assert.equal(c.route.rules.indexOf(reject),2,'reject after sniff/DNS and before outbound routing');
}
JS
ucode -L "$LIB" -e 'let m=require("diagnostics.route_match");let r=m.explain({route:{rules:[{action:"predefined",rcode:"NXDOMAIN",domain:"v6.xy.fbcdn.net"}]}},{domain:"v6.xy.fbcdn.net"},{},{});assert(r.status=="blocked","DNS explanation must recognize probe filter");'
ucode -L "$LIB" -e '
let m=require("diagnostics.route_match"),f=require("fs"),c=json(f.readfile(ARGV[0])),rule=filter(c.dns.rules,(r)=>r.action=="predefined")[0];
let config={route:{rules:[rule,{action:"route",server:"allowed"}]}};
for(let name in ["v6.xy.fbcdn.net","fa4e35f8-5be3-4814-af28-573a3fe281ed-netseer-ipaddr-assoc.xy.fbcdn.net","sonar6.fhrk1-1.fna.fbcdn.net","sonar6-ams2-1.xx.fbcdn.net","brunhild.challenges.cloudflare.com"])
 assert(m.explain(config,{domain:name},{},{}).status=="blocked","probe DNS explanation: "+name);
for(let name in ["sonar6-ams2-1.xy.fbcdn.net","sonar6-ams2-1.xx.fbcdn.net.evil.test","ya.ru","scontent.xy.fbcdn.net","challenges.cloudflare.com","brunhild.challenges.cloudflare.com.evil.test","v6.xy.fbcdn.net.evil.test"])
 assert(m.explain(config,{domain:name},{},{}).outbound=="allowed","ordinary DNS must fall through: "+name);
' "$WORK_DIR/ipv4_only-1.json"
ucode -L "$LIB" -e '
let m=require("diagnostics.route_match"),f=require("fs"),c=json(f.readfile(ARGV[0]));
for(let network in ["tcp","udp"])
 for(let name in ["v6.xy.fbcdn.net","sonar6-ams2-1.xx.fbcdn.net","brunhild.challenges.cloudflare.com"])
  assert(m.explain(c,{domain:name,inbound:"tproxy-in",network,protocol:network=="tcp"?"tls":"quic"},{},{}).status=="blocked","probe connection must be rejected: "+name);
' "$WORK_DIR/ipv4_only-1.json"
printf 'IPv4 probe DNS and connection filtering checks passed\n'
