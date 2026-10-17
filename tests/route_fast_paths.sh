#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let matcher=require("diagnostics.route_match"),codec=require("diagnostics.route_decode_cache"),calls=0;
let sets=(tag,request,mode)=>{calls++;return {value:"unknown",missing:["rule_set:"+tag]};};
let request={domain:"youtube.com",source_ip:"192.0.2.5",destination_ip:"203.0.113.1",port:443,network:"tcp"};
let config={route:{rules:[{rule_set:"large",source_ip_cidr:"198.51.100.0/24",outbound:"wrong"},{rule_set:"large",port:8443,outbound:"wrong"}],final:"direct-out"}};
let result=matcher.explain(config,request,{},sets);
assert(result.status=="direct" && calls==0,"definite source/port failures do not decode irrelevant lists");
let rule={type:"remote",format:"binary",url:"https://github.com/itdoginfo/allow-domains/releases/latest/download/youtube.srs"};
assert(type(codec.domain_only)=="function" && codec.domain_only(rule),"canonical domain-only community set uses native matching");
assert(!codec.domain_only({...rule,url:"https://github.com/itdoginfo/allow-domains/releases/latest/download/meta.srs"}),"mixed domain/IP set must keep full matching");
assert(!codec.domain_only({...rule,url:"https://other.example/domains/youtube.srs"}),"URL substring is not a schema guarantee");
assert(!codec.domain_only({...rule,format:"source"}),"source schemas retain validation");
print("route fast path safety checks passed\n");
'
