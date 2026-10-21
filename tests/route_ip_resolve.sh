#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/singbox/route.uc" <<'JS'
const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
let source=fs.readFileSync(process.argv[2],'utf8');
source=source.slice(0,source.lastIndexOf('\nreturn {')).replace(/for \(let key in /g,'for (let key of ');
const ctx={require:name=>({
  'core.common':{option:(o,k,d)=>o[k]??d,bool_option:(o,k,d)=>o[k]==null?d:['1','yes','true',true].includes(o[k])},
  'config.connections':{is_connections_action:a=>['connection','outbound','vpn'].includes(a)},
  'singbox.constants':{DNS_SERVER_TAG:'dns-server'}
}[name])};vm.createContext(ctx);vm.runInContext(source,ctx);
const plain=x=>JSON.parse(JSON.stringify(x));
const section={'.name':'DE',action:'connection',resolve_real_ip_for_routing:'1'};
const guards={inbound:['tproxy-in','tproxy6-in'],source_ip_cidr:['192.0.2.0/24'],port:[443],port_range:['8000:8100']};
for(const destination of [
  {rule_set:['DE-cloudflare','community-cloudflare-ipv4','community-cloudflare-ipv6']},
  {rule_set:'custom-mixed'},
  {ip_cidr:['104.16.0.0/13']},
  {ip_cidr:['104.16.0.0/13'],domain_suffix:['listed.example']}
]) {
  const rule={...guards,...destination,action:'route',outbound:'DE-out'},original=JSON.stringify(rule);
  const resolve=plain(ctx.resolve_rule_for_section(section,rule));
  assert.deepEqual(resolve,{rule:{...guards,action:'resolve',server:'dns-server'}},'resolve must run before destination-IP/rule-set matching');
  assert.equal(JSON.stringify(rule),original,'final route matchers must remain unchanged');
}
const domain={...guards,domain_suffix:['listed.example'],action:'route',outbound:'DE-out'};
assert.deepEqual(plain(ctx.resolve_rule_for_section(section,domain)),{rule:{...guards,domain_suffix:['listed.example'],action:'resolve',server:'dns-server'}});
for(const action of ['bypass','block','zapret2'])assert.equal(ctx.resolve_rule_for_section({...section,action},domain),null);
assert.equal(ctx.resolve_rule_for_section({...section,resolve_real_ip_for_routing:'0'},domain),null);
assert(ctx.resolve_rule_for_section(section,guards).warning,'empty destination still warns');
assert.equal(ctx.resolve_rule_for_section({...section,action:'byedpi',resolve_real_ip_for_routing:'0'},domain).rule.action,'resolve');
console.log('Destination-IP resolve prerequisites and unchanged routing guards passed');
JS
