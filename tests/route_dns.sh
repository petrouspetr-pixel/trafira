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
assert(dns.resolve({}, {domain:"example.com",source:{kind:"router"}},{}).status=="unavailable","no external resolver fallback");
print("route DNS checks passed\n");
'
