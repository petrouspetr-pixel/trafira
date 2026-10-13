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
node -e 'const b=Buffer.alloc(60*1024*1024,1);setInterval(()=>console.log(b.length),1000)' >"$WORK_DIR/child.log" &
child=$!
ucode -L "$TRAFIRA_LIB" -e 'let f=require("fs"),m=require("diagnostics.route_memory");f.writefile(ARGV[0],sprintf("%J",m.identity(ARGV[1])));' "$WORK_DIR/r-dead/calculator.json" "$child"
ticks="$(awk '{print $22}' /proc/$$/stat)"
ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/diagnostics/route_memory.uc" watch "$WORK_DIR/r-dead" "$$" "$ticks"
if wait "$child"; then echo 'FAIL: memory-heavy worker survived' >&2; exit 1; fi
test "$(cat "$WORK_DIR/r-dead/memory.error")" = resource_limit
printf 'resident memory monitor terminates oversized worker without network or service changes\n'
