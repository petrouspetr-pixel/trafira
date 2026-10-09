#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT/components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp" -e '
let s=require("warp.scout");
let account={id:"fixture-account",token:"fixture-token",private_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",peer_public_key:"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",ipv4:"172.16.0.2",ipv6:"2606:4700:110:8::2"};
assert(s.account_valid(account),"valid private account");
let text="[Interface]\nPrivateKey = "+account.private_key+"\nJc = 5\nJmin = 10\nJmax = 50\nI1 = <b 0x01>\n[Peer]\nPublicKey = "+account.peer_public_key+"\nEndpoint = 162.159.192.1:2408\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n";
assert(s.parse_candidate(text,account,"tfwarp0",134217728).success,"safe candidate");
assert(s.parse_candidate(replace(text,"AllowedIPs = 0.0.0.0/0, ::/0","AllowedIPs = 0.0.0.0/0"),account,"tfwarp0",134217728).success,"actual IPv4 Scout output normalizes dual-family transport");
assert(!s.parse_candidate(text+"PostUp = arbitrary command\n",account,"tfwarp0",134217728).success,"no executable config directives");
assert(!s.parse_candidate(text+"Endpoint = 127.0.0.1:443\n",account,"tfwarp0",134217728).success,"duplicate endpoint rejected");
assert(!s.parse_candidate(text,account,"tfwarp0",67108864).success,"capture mark rejected");
let candidate={account_digest:"abc",generation:1,expires_at:200};
assert(s.candidate_current(candidate,"abc",1,100),"same registration/generation");
assert(!s.candidate_current(candidate,"changed",1,100) && !s.candidate_current(candidate,"abc",2,100) && !s.candidate_current(candidate,"abc",1,201),"stale candidate rejected");
print("WARP candidate checks passed\n");
'
