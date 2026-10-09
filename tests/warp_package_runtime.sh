#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/trafira-warp-package.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export FIXTURE="$WORK" TRAFIRA_LIB="$WORK/lib" TRAFIRA_WARP_PACKAGE_CACHE="$WORK/cache"
mkdir -p "$WORK/lib/components" "$WORK/lib/integrations" "$WORK/cache" "$WORK/work"
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
source=(root/'trafira/files/usr/lib/components/warp_package_runtime.uc').read_text()
source=source.replace('/etc/init.d/trafira-warp',str(work/'service'))
(work/'lib/components/warp_package_runtime.uc').write_text(source)
PY
cat >"$WORK/service" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$FIXTURE/service.calls"
SH
chmod +x "$WORK/service"
cat >"$WORK/lib/components/core_sources.uc" <<'UC'
let fs=require("fs");
function download(url,path) {
 let root=getenv("FIXTURE");
 if(fs.stat(root+"/offline"))throw "unexpected network access";
 let source=index(url,"api.github.com")>=0?"release.json":substr(url,rindex(url,"/")+1);
 let text=fs.readfile(root+"/assets/"+source);if(text==null)return false;
 return fs.writefile(path,text)==length(text);
}
return {download};
UC
cat >"$WORK/lib/integrations/warp_cli.uc" <<'UC'
let fs=require("fs"),action=ARGV[1],path=ARGV[2],root=getenv("FIXTURE");
assert(ARGV[0]=="package-state","internal state command");
if(action=="snapshot")fs.writefile(path,sprintf("%J",{transport:{running:false},files:{}}));
else if(action=="resume" || action=="restore") {
 let state=json(fs.readfile(path));assert(state.transport.running===false,"stopped state preserved");
 fs.writefile(root+"/state-operation",action);
}else exit(1);
exit(0);
UC
ucode -L "$WORK/lib" -L "$ROOT/trafira/files/usr/lib" "$ROOT/tests/helpers/warp_package_fixture.uc"
