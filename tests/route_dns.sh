#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
mkdir "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
export DNS_FIXTURE="$WORK_DIR/answer" DNS_CALLS="$WORK_DIR/calls"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$DNS_CALLS"
case "${DNS_TEST_MODE:-}" in
 hang) printf '%s' "$$" >"$DNS_CHILD_PID"; exec sleep 15;;
 partial) case " $* " in *' AAAA '*) exit 9;; esac;;
esac
cat "$DNS_FIXTURE"
SH
chmod +x "$WORK_DIR/bin/dig"
printf 'alias.example.\n203.0.113.5\n203.0.113.6\n203.0.113.5\n' >"$DNS_FIXTURE"
ucode -L "$TRAFIRA_LIB" -e '
let dns=require("diagnostics.route_dns"),fs=require("fs");
let c={inbounds:[{tag:"dns-health-active-main-in",listen:"127.0.0.42",listen_port:12053}],dns:{servers:[{type:"fakeip",inet4_range:"198.18.0.0/15"}]}};
let r=dns.resolve(c,{domain:"example.com",source:{kind:"device",ip:"192.168.1.2"}},{dns_strategy:"ipv4_only"});
assert(r.status=="resolved" && length(r.addresses)==2 && r.addresses[0]=="203.0.113.5","real addresses deduplicated");
assert(index(fs.readfile(getenv("DNS_CALLS")),"@127.0.0.42")>=0,"uses local main DNS only");
fs.writefile(getenv("DNS_FIXTURE"),"198.18.0.5\n");
assert(dns.resolve(c,{domain:"example.com",source:{kind:"device",ip:"192.168.1.2"}},{}).status=="fakeip","FakeIP cannot decide CIDR route");
fs.writefile(getenv("DNS_FIXTURE"),"203.0.113.1\n203.0.113.2\n203.0.113.3\n203.0.113.4\n203.0.113.5\n");
r=dns.resolve(c,{domain:"example.com",source:{kind:"device",ip:"192.168.1.2"}},{});
assert(length(r.addresses)==4 && r.truncated,"bounded answers disclose truncation");
fs.writefile(getenv("DNS_FIXTURE"),"");
assert(dns.resolve(c,{domain:"example.com",source:{kind:"device",ip:"192.168.1.2"}},{}).status=="no_address","empty DNS is not a confirmed route");
let before=fs.readfile(getenv("DNS_CALLS"));
r=dns.resolve(c,{domain:"example.com",destination_ip:"203.0.113.8",source:{kind:"router"}},{});
assert(!r.performed && r.origin=="manual" && r.addresses[0]=="203.0.113.8","manual override skips DNS");
assert(fs.readfile(getenv("DNS_CALLS"))==before,"no DNS on override");
fs.writefile(getenv("DNS_FIXTURE"),"2001:db8::1\n203.0.113.1\n");
r=dns.resolve(c,{domain:"example.com",source:{kind:"device",ip:"2001:db8::2"}},{dns_strategy:"ipv4_only"});
assert(length(r.addresses)==1 && r.addresses[0]=="2001:db8::1" && r.family=="ipv6","selected source family is never mixed with an incompatible destination");
assert(dns.resolve({}, {domain:"example.com",source:{kind:"router"}},{}).status=="unavailable","no external resolver fallback");
print("route DNS checks passed\n");
'

export DNS_CHILD_PID="$WORK_DIR/child.pid"
DNS_TEST_MODE=hang ucode -L "$TRAFIRA_LIB" -e '
let dns=require("diagnostics.route_dns"),fs=require("fs"),started=clock(true);
let config={inbounds:[{tag:"dns-health-active-main-in",listen:"127.0.0.42",listen_port:12053}]};
let r=dns.resolve(config,{domain:"example.com",source:{kind:"device",ip:"192.168.1.2"}},{},ARGV[0]),ended=clock(true);
let elapsed=(ended[0]-started[0])+(ended[1]-started[1])/1000000000;
assert(r.status=="timeout" && !length(r.addresses),"hung DNS remains a timeout, never a confirmed route");
assert(elapsed>=5 && elapsed<10,"outer deadline permits five-second DNS wait but bounds a hung process");
assert(!fs.stat(ARGV[0]+"/dns-answer"),"timed-out response file is cleaned");
let pid=trim(fs.readfile(getenv("DNS_CHILD_PID")));
assert(system("kill -0 "+pid+" 2>/dev/null")!=0,"hung DNS child has been reaped");
print("route DNS five-second wait and hung-child deadline passed\n");
' "$WORK_DIR"

printf '203.0.113.5\n' >"$DNS_FIXTURE"
DNS_TEST_MODE=partial ucode -L "$TRAFIRA_LIB" -e '
let dns=require("diagnostics.route_dns");
let config={inbounds:[{tag:"dns-health-active-main-in",listen:"127.0.0.42",listen_port:12053}]};
let r=dns.resolve(config,{domain:"example.com",source:{kind:"router"}},{dns_strategy:"prefer_ipv4"});
assert(r.status=="resolved" && r.partial && r.family=="both" && r.addresses[0]=="203.0.113.5","second-family timeout preserves the successful addresses and discloses partial results");
print("route DNS partial-family timeout passed\n");
'
