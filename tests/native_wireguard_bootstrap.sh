#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let b=require("singbox.ruleset_bootstrap"),clone=v=>json(sprintf("%J",v));
let endpoint={type:"wireguard",tag:"wg-native",system:true,name:"production-wg",listen_port:51821,address:["10.200.0.2/32"],private_key:"test-private-key",mtu:1280,peers:[{address:"peer.example",port:51820,public_key:"test-public-key",pre_shared_key:"test-psk",allowed_ips:["0.0.0.0/0"],persistent_keepalive_interval:25}]};
let c={endpoints:[endpoint],outbounds:[{type:"selector",tag:"download",outbounds:["wg-native"],default:"wg-native"},{type:"socks",tag:"proxy",server:"192.0.2.2",server_port:1080,detour:"wg-native"}],dns:{servers:[{tag:"bootstrap-dns-server",type:"udp",server:"9.9.9.9"}]},route:{rule_set:[{type:"remote",tag:"test",url:"https://example.org/list.srs",http_client:{detour:"download"}}]}};
let before=sprintf("%J",c),p=b.plan(c);
assert(!p.error && length(p.candidates)==1 && p.candidates[0]=="wg-native","native endpoint is a usable selected candidate");
let stage=b.stage(c,"wg-native",4539),ep=(stage.endpoints||[])[0];
assert(ep && length(stage.endpoints)==1 && length(stage.outbounds)==0,"native endpoint retained outside outbounds");
assert(ep.system===false && ep.name==null && ep.listen_port==0,"temporary endpoint creates no system interface or fixed port");
assert(ep.private_key==endpoint.private_key && ep.peers[0].pre_shared_key==endpoint.peers[0].pre_shared_key,"cryptographic profile preserved");
assert(ep.mtu==1280 && ep.address[0]=="10.200.0.2/32" && ep.peers[0].address=="peer.example" && ep.peers[0].allowed_ips[0]=="0.0.0.0/0","endpoint transport and addresses preserved");
assert(ep.peers[0].persistent_keepalive_interval==0 && ep.domain_resolver=="bootstrap-dns-server","no idle peer traffic and independent DNS");
let chained=b.stage(c,"proxy",4539);
assert(chained.outbounds[0].detour=="wg-native" && chained.endpoints[0].tag=="wg-native","proxy over native WireGuard preserves dependency");
assert(sprintf("%J",c)==before,"bootstrap never mutates main profile");
let other=clone(c);other.endpoints[0].type="tailscale";
assert(b.plan(other).error!=null,"other endpoint types remain explicitly unsupported");
let cycle=clone(c);cycle.endpoints[0].detour="download";
assert(b.stage(cycle,"wg-native",4539).error!=null,"endpoint detour cycles rejected");
print("native WireGuard bootstrap graph checks passed\n");
'
