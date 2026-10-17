#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/nft" <<'PY'
#!/usr/bin/env python3
import os,sys
assert sys.argv[1:5]==['-s','list','set','inet']
table,name=sys.argv[5:]
mode=os.getenv('NFT_READ_MODE','good')
if mode=='failed': sys.exit(1)
if mode=='oversize': print('x'*1100000);sys.exit()
kind='ipv6_addr' if name.endswith('6') else 'ipv4_addr'
if mode=='wrong_type': kind='inet_service'
elements='2001:db8::/32' if name.endswith('6') else '192.0.2.0/24, 198.51.100.1'
print('table inet '+table+' {\n set '+name+' {\n type '+kind+'; flags interval; auto-merge;')
if mode!='empty': print('elements = { '+elements+' }')
if mode!='truncated': print('}\n}')
PY
chmod +x "$WORK_DIR/bin/nft"
cat >"$WORK_DIR/check.uc" <<'UC'
let retained=require("nft.reload_sets"),fs=require("fs");
let definitions={v4:"{ type ipv4_addr; flags interval; auto-merge; }",v6:"{ type ipv6_addr; flags interval; auto-merge; }"};
let result=retained.load("Fixture",definitions);
if(ARGV[0]=="reject")assert(result==null,"unusable snapshots must select the normal rebuild/update path");
else {
 assert(result && length(keys(result))==2,"both family sets retained");
 assert(index(result.v4,ARGV[0]=="empty"?"type ipv4_addr":"192.0.2.0/24")>=0,"IPv4 snapshot retained exactly");
 assert(index(result.v6,ARGV[0]=="empty"?"type ipv6_addr":"2001:db8::/32")>=0,"IPv6 snapshot retained exactly");
 let tx=require("nft.transaction").create();
 assert(tx.append("delete table inet Fixture\nadd table inet Fixture\n"),"rebuild staged");
 for(let name in keys(result))assert(tx.command(["add","set","inet","Fixture",name,result[name]]),"snapshot in same transaction");
}
assert(retained.load("bad;name",definitions)==null,"invalid table never executed");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/check.uc" good
NFT_READ_MODE=empty ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/check.uc" empty
for mode in failed oversize wrong_type truncated; do
  NFT_READ_MODE=$mode ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/check.uc" reject
done
echo 'Bounded kernel set snapshots preserve both families and reject unusable data before writes'
