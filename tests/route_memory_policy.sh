#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
ucode -L "$TRAFIRA_LIB" -e 'let m=require("diagnostics.route_memory");assert(m.over_budget({rss:50*1024*1024,temporary:0,available:100*1024*1024}),"combined RSS ceiling");assert(m.over_budget({rss:40*1024*1024,temporary:10*1024*1024,available:100*1024*1024}),"temporary RAM accounted");assert(m.over_budget({rss:1,temporary:0,available:16*1024*1024}),"free memory reserve");assert(!m.over_budget({rss:10*1024*1024,temporary:1024,available:100*1024*1024}),"ordinary request allowed");let s=m.sample(m.identity());assert(s.rss>0 && s.available>0,"actual process and available memory sampled");'
printf 'route memory policy checks passed\n'

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/r-dead"
printf '{"running":true}' >"$WORK_DIR/r-dead/state.json"
node -e 'const b=Buffer.alloc(150*1024*1024,1);setInterval(()=>console.log(b.length),1000)' >"$WORK_DIR/child.log" &
child=$!
ucode -L "$TRAFIRA_LIB" -e 'let f=require("fs"),m=require("diagnostics.route_memory");f.writefile(ARGV[0],sprintf("%J",m.identity(ARGV[1])));' "$WORK_DIR/r-dead/calculator.json" "$child"
ticks="$(awk '{print $22}' /proc/$$/stat)"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/route_memory.uc" watch "$WORK_DIR/r-dead" "$$" "$ticks"
if wait "$child"; then echo 'FAIL: memory-heavy worker survived' >&2; exit 1; fi
test "$(cat "$WORK_DIR/r-dead/memory.error")" = resource_limit
printf 'resident memory monitor terminates oversized worker without network or service changes\n'

ucode -L "$TRAFIRA_LIB" -e 'let m=require("diagnostics.route_match"),sets={sample:{rules:[{port:8443,source_ip_cidr:"192.0.2.0/24"},{ip_cidr:"192.0.2.0/24"}]}},request={domain:"target.example",source_ip:"192.0.2.5",destination_ip:"203.0.113.10",port:443,network:"tcp"};let config={route:{rules:[{action:"route-options",override_port:8443},{rule_set:"sample",rule_set_ip_cidr_match_source:true,outbound:"vpn-out"}],final:"direct-out"}};let calls=0;let callback=(tag,current,mode)=>{calls++;return m.match_rule({rule_set:tag,rule_set_ip_cidr_match_source:mode},current,sets);};let expected=m.explain(config,request,{},sets),actual=m.explain(config,request,{},callback);assert(sprintf("%J",expected)==sprintf("%J",actual) && actual.outbound=="vpn-out" && calls==1,"lazy source mode and route-options parity");'

# Force the OpenWrt kernel fallback even on CI kernels with children support.
sed 's@let children=fs.readfile(.*);@let children=null;@' "$TRAFIRA_LIB/diagnostics/route_memory.uc" >"$WORK_DIR/fallback.uc"
ucode -L "$WORK_DIR" -L "$TRAFIRA_LIB" -e 'let fs=require("fs"),m=require("fallback");assert(m.memory_budget(512*1024*1024)==128*1024*1024,"large router budget capped");assert(m.memory_budget(128*1024*1024)==32*1024*1024,"small router limited to quarter RAM");let pipe=fs.popen("echo ready; sleep 20","r");pipe.read("line");let seen={},processes=m.tree(m.identity(),seen);assert(!seen.unavailable && length(processes)>=2,"PPID fallback finds live child");m.stop(slice(processes,1));pipe.close();'
