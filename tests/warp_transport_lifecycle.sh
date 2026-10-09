#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FIXTURE="$WORK" TRAFIRA_WARP_STATE="$WORK/state" TRAFIRA_WARP_RUNTIME="$WORK/run"
mkdir -p "$WORK/lib/warp" "$WORK/bin"
cp "$ROOT"/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp/warp/*.uc "$WORK/lib/warp/"
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);p=root/'lib/warp/transport.uc';p.write_text(p.read_text().replace('/etc/init.d/trafira-warp',str(root/'service')))
PY
cat >"$WORK/service" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$FIXTURE/services"
[ "$1" != start ]
SH
cat >"$WORK/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE/ubus"
[ ! -f "$FIXTURE/fail-ubus" ]
SH
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
 *'-j rule show'*|*'-j route show'*) printf '[]\n';;
 *'rule show'*) [ ! -f "$FIXTURE/collision" ] || printf '101: from all fwmark 0x08000000/0xff000000 lookup other\n';;
 *) exit 1;;
esac
exit 0
SH
chmod +x "$WORK/service" "$WORK/bin/ip" "$WORK/bin/ubus"
cat >"$WORK/lib/uci.uc" <<'UC'
let fs=require("fs"),file=getenv("FIXTURE")+"/network.json",rows={};
function load(){try{rows=json(fs.readfile(file));}catch(e){rows={};}}
return {cursor:()=>{load();return {
 get_all:(pkg,name)=>rows[name],
 set:(pkg,name,key,value)=>{if(value==null)rows[name]={".type":key};else rows[name][key]=value;return true;},
 delete:(pkg,name)=>{delete rows[name];return true;},
 commit:()=>!fs.stat(getenv("FIXTURE")+"/fail-commit") && fs.writefile(file,sprintf("%J",rows))>0
};}};
UC
PATH="$WORK/bin:$PATH" ucode -L "$WORK/lib" -e '
let fs=require("fs"),t=require("warp.transport"),s=require("warp.state"),root=getenv("FIXTURE");
let c={interface:"tfwarp0",endpoint:"162.159.192.1:2408",fwmark:134217728,mtu:1280,ipv4:"172.16.0.2",ipv6:"fd42::2",private_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",peer_public_key:"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",jc:5,jmin:10,jmax:50,i1:"<b 0x01>",enabled:false};
fs.writefile(root+"/network.json",sprintf("%J",{tfwarp0:{".type":"interface",proto:"foreign"},wan:{".type":"interface",proto:"dhcp"}}));
assert(t.apply(c,"fixture").error=="interface_conflict" && !fs.stat(root+"/services"),"foreign section untouched before service stop");
fs.writefile(root+"/network.json",sprintf("%J",{wan:{".type":"interface",proto:"dhcp"}}));fs.writefile(root+"/collision","");
assert(!t.mark_available(c.fwmark) && t.apply(c,"fixture").error=="invalid_transport","masked hexadecimal route collision rejected");fs.unlink(root+"/collision");
let before=t.snapshot();assert(t.apply(c,"fixture").success,"inactive owned transport configured");
let network=json(fs.readfile(root+"/network.json"));assert(network.wan.proto=="dhcp" && network.tfwarp0.delegate=="0","foreign network and global defaults unchanged");
assert(t.status().configured && !t.status().running,"verified absent owned interface");
assert(fs.readfile(root+"/services")=="stop\n","disabled apply never starts service");
let saved=t.snapshot();assert(t.apply({...c,enabled:true},"fixture").error=="start_failed","failed service start reported");
assert(t.restore(saved,"fixture") && s.load(s.DIRECTORY+"/transport.json").enabled===false,"disabled state restored after start failure");
assert(t.restore(before,"fixture"),"restore pre-registration transport");
network=json(fs.readfile(root+"/network.json"));assert(!network.tfwarp0 && network.wan.proto=="dhcp","only owned UCI removed");
fs.writefile(root+"/fail-ubus","");assert(t.apply(c,"fixture").error=="network_apply_failed","netifd failure reported");fs.unlink(root+"/fail-ubus");assert(t.restore(before,"fixture"),"partial network mutation recovered");
print("WARP transport ownership, mark conflicts, start/netifd failure and disabled rollback passed\n");
'
