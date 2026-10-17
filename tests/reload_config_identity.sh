#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CONFIG_FILE="$WORK_DIR/current" TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" FIXTURE_CORE="$WORK_DIR/core"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),applied=require("service.applied_config"),n=applied.normalized;
let original="config settings settings\n option dns_server 1.1.1.1\n option shutdown_correctly 1\n\nconfig section first\n option action bypass\n list ip_cidr 192.0.2.0/24\n list ip_cidr 198.51.100.0/24\n\nconfig section second\n option action proxy\n";
let canonical="\n# saved by UCI\nconfig \u0027settings\u0027 \u0027settings\u0027\n\toption \u0027shutdown_correctly\u0027 \u00270\u0027\n\toption dns_server \u00271.1.1.1\u0027\n\nconfig section \u0027first\u0027\n\tlist ip_cidr \u0027192.0.2.0/24\u0027\n\toption action \u0027bypass\u0027\n\tlist ip_cidr \u0027198.51.100.0/24\u0027\n\nconfig section \u0027second\u0027\n\toption action \u0027proxy\u0027\n\n";
assert(n(original)==n(canonical),"UCI formatting, option order and lifecycle hint cannot queue another reload");
assert(n(original)!=n(replace(original,"1.1.1.1","9.9.9.9")),"DNS user changes are detected");
assert(n(original)!=n(replace(original,"option action bypass","option action block")),"routing action changes are detected");
let reverse="config settings settings\n option dns_server 1.1.1.1\nconfig section second\n option action proxy\nconfig section first\n option action bypass\n list ip_cidr 192.0.2.0/24\n list ip_cidr 198.51.100.0/24\n";
assert(n(original)!=n(reverse),"section priority remains significant");
assert(n(original)!=n(replace(original,"list ip_cidr 192.0.2.0/24\n list ip_cidr 198.51.100.0/24","list ip_cidr 198.51.100.0/24\n list ip_cidr 192.0.2.0/24")),"list ordering remains significant");
assert(n("config section x\n option label \u0027a  # b\u0027\n")!=n("config section x\n option label \u0027a # b\u0027\n"),"spaces and hashes inside values are significant");
assert(n("config section x\n option shutdown_correctly 1\n")!=n("config section x\n option shutdown_correctly 0\n"),"only the settings lifecycle flag is ignored");
assert(n("config settings settings\n option bootstrap_dns_server \u0027\u0027\n list bootstrap_dns_server 1.1.1.1\n")!=n("config settings settings\n list bootstrap_dns_server \u0027\u0027\n list bootstrap_dns_server 1.1.1.1\n"),"an empty scalar deletes an option; an empty list item remains significant");
assert(n("config settings settings\n option unused \u0027\u0027\n")==n("config settings settings\n"),"libuci drops empty scalar options when committing");
assert(n("config section \u0027\u0027\n option unused\n")==n("config section\n"),"optional empty name/value survives UCI commit");
assert(n("c section x\n o value example\n l servers 1.1.1.1\n")==n("config section x\n option value example\n list servers 1.1.1.1\n"),"native UCI command aliases are canonicalized");
assert(n("\u0027config\u0027 settings settings\n")!=n("config settings settings\n"),"quoted command must not match valid UCI");
assert(n("con\u0027fig\u0027 settings settings\n")!=n("config settings settings\n"),"quote concatenation is allowed for arguments, not commands");
assert(n("config settings settings\n option \u0027\u0027 \u0027\u0027\n")!=n("config settings settings\n"),"invalid empty option name cannot masquerade as a no-op");
assert(n("config \u0027\u0027 settings\n")!=n("config settings settings\n"),"invalid empty section type keeps exact identity");
assert(n("config section x\n option label \u0027a\u0027\\\u0027\u0027b\u0027\n")==n("config section x\n option label \"a\u0027b\"\n"),"exported single quote escaping preserves literal values");
fs.writefile(getenv("TRAFIRA_CONFIG_FILE"),original);fs.writefile(getenv("FIXTURE_CORE"),"{}");
let checkpoint=applied.capture({config_path:getenv("FIXTURE_CORE")},[]);
fs.writefile(getenv("TRAFIRA_CONFIG_FILE"),canonical);
assert(applied.save(checkpoint),"canonical UCI commit preserves the verified checkpoint");
fs.writefile(getenv("TRAFIRA_CONFIG_FILE"),replace(canonical,"1.1.1.1","9.9.9.9"));
assert(!applied.save(checkpoint),"concurrent real user change refuses stale checkpoint");
print("reload configuration identity checks passed\n");
'
# Exercise the actual lifecycle decision, not a second copy of its comparison.
python3 - "$ROOT_DIR" "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
root, work=map(Path,sys.argv[1:])
source=(root/'trafira/files/usr/lib/service/lifecycle.uc').read_text()
fingerprint=source[source.index('function external_config_fingerprint() {'):source.index('\nfunction trim(value) {')]
decision=source[source.index('function mark_pending_reload_if_config_changed('):source.index('\nfunction module_output(')]
(work/'decision.uc').write_text('''let fs=require("fs"),CONFIG_FILE=getenv("TRAFIRA_CONFIG_FILE");
function as_string(v){return v==null?"":""+v;}
let pending=0;function mark_pending_reload(){pending++;return true;}
function pending_reload_log_context(){return "reload";}function log_message(){}
''' + fingerprint + decision + '''
fs.writefile(CONFIG_FILE,"config settings settings\\n option label value\\n");
let before=external_config_fingerprint();
fs.writefile(CONFIG_FILE,"\\nconfig settings 'settings'\\n\\toption label 'value'\\n\\toption shutdown_correctly '0'\\n\\n");
assert(finish_reload_status(0,before)==0 && pending==0,"no second reload after internal serialization");
fs.writefile(CONFIG_FILE,"config settings settings\\n option label changed\\n");
assert(finish_reload_status(0,before)==0 && pending==1,"real concurrent edit queues a follow-up");
assert(finish_reload_status(1,before)==1 && pending==1,"failed apply does not queue another apply");
print("lifecycle reload decision checks passed\\n");
''')
PY
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/decision.uc"
