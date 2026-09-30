#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR" "$WORK_DIR" <<'NODE'
const fs = require('fs');
const [root, dir] = process.argv.slice(2);
let source = fs.readFileSync(root+'/trafira/files/usr/lib/dns/apply.uc','utf8');
source = source.slice(source.indexOf('const CONFIG_NAME'), source.indexOf('let mode = ARGV'));
const setup = `let data = {}; let fail_write = false; let fail_commit = false; let restart_ok = true;
let uci = {
 available: () => true, get: p => data[p] == null ? "" : data[p],
 exists: p => data[p] != null,
 set: (p,v) => { if(fail_write) return false; data[p] = v; return true; },
 delete: p => { if(fail_write) return false; delete data[p]; return true; },
 add_list: (p,v) => { if(fail_write) return false; data[p] = data[p] ? data[p]+" "+v : v; return true; },
 del_list: (p,v) => { if(fail_write) return false; let a=[]; for(let x in split(data[p] || "", " ")) if(x != v) push(a,x); if(length(a)) data[p]=join(" ",a); else delete data[p]; return true; },
 commit: p => !fail_commit
};
let system = command => index(command, " restart") >= 0 && !restart_ok ? 1 : 0;
function assert(ok, message) { if(!ok) { warn(message+"\\n"); exit(1); } }
const p = "dhcp.@dnsmasq[0].";
`;
const cases = {
 external: `data[p+"server"]="1.1.1.1"; data[p+"noresolv"]="0"; data[p+"cachesize"]="150";
assert(dnsmasq_configure("force"), "configure"); data[p+"server"]="9.9.9.9"; data[p+"noresolv"]="2"; data[p+"cachesize"]="999";
assert(failsafe_restore(), "restore"); assert(data[p+"server"]=="9.9.9.9", "external server overwritten"); assert(data[p+"noresolv"]=="2" && data[p+"cachesize"]=="999", "external scalar overwritten");`,
 absent: `assert(dnsmasq_configure("force"), "configure absent"); assert(dnsmasq_configure("force"), "configure twice"); assert(failsafe_restore(), "restore absent"); assert(data[p+"server"]==null && data[p+"noresolv"]==null && data[p+"cachesize"]==null, "absent originals must stay absent");`,
 appended: `data[p+"server"]="1.1.1.1"; assert(dnsmasq_configure("force"), "configure"); data[p+"server"]="127.0.0.42 9.9.9.9"; assert(failsafe_restore(), "restore"); assert(data[p+"server"]=="9.9.9.9", "preserve externally appended servers without reinstating stale backup");`,
 legacy_interfaces: `data["dhcp.trafira"]="dnsmasq"; data["dhcp.trafira.interface"]="br-lan"; data[p+"notinterface"]="br-lan guest"; data[p+"trafira_notinterface"]="wan"; assert(failsafe_restore(), "legacy interface restore"); assert(data[p+"notinterface"]=="guest", "legacy cleanup overwrote external interface");`,
 legacy_external: `data[p+"server"]="9.9.9.9"; data[p+"trafira_server"]="1.1.1.1"; assert(failsafe_restore(), "legacy restore"); assert(data[p+"server"]=="9.9.9.9", "legacy backup overwrote external server");`,
 restart_error: `assert(dnsmasq_configure("force"), "configure"); restart_ok=false; assert(!failsafe_restore(), "restart failure swallowed");`,
 snapshot_commit_error: `data[p+"server"]="1.1.1.1"; fail_commit=true; assert(!dnsmasq_configure("force"), "snapshot commit failure swallowed"); assert(data[p+"server"]=="1.1.1.1", "DNS changed without durable backup");`,
 commit_error: `assert(dnsmasq_configure("force"), "configure"); fail_commit=true; assert(!failsafe_restore(), "commit failure swallowed");`,
 write_error: `fail_write=true; assert(!dnsmasq_configure("force"), "write failure swallowed");`
};
for(const [name, body] of Object.entries(cases)) fs.writeFileSync(dir+'/dns-'+name+'.uc',setup+source+body);
const pkg=fs.readFileSync(root+'/trafira/files/usr/lib/service/package.uc','utf8');
const names=['prerm_cleanup','remember_upgrade_state'];
const funcs=names.map(n=>{const s=pkg.indexOf('function '+n+'(');return {s,c:pkg.slice(s,pkg.indexOf('\n}',s)+2)};}).sort((a,b)=>a.s-b.s).map(x=>x.c).join('\n');
fs.writeFileSync(dir+'/package.uc', `let calls=[]; let state=false; let restore_ok=true; let stop_ok=true;
let as_string=v=>v==null ? "" : ""+v; let env=(n,f)=>f;
const PACKAGE_TEST_MODE=false; const PACKAGE_UPGRADE_STATE="state"; const INIT_PATH="init";
let command_success_from_args=a=>a[1]=="stop" ? stop_ok : true;
let fs={writefile: (p,v)=>{state=true; return length(v);}};
let unlink_if_exists=p=>{state=false;};
let remove_managed_sing_box=()=>{push(calls,"remove");};
let restore_dnsmasq_if_needed=()=>restore_ok;
let remove_tproxy_firewall_include=()=>true; let remove_rt_tables_entry=()=>true;
function assert(ok,m){if(!ok){warn(m+"\\n");exit(1);}}
`+funcs+`
assert(prerm_cleanup("upgrade"),"upgrade"); assert(length(calls)==0,"upgrade deleted managed binary"); assert(state,"upgrade state missing");
assert(prerm_cleanup(""),"ambiguous opkg prerm"); assert(length(calls)==0,"empty operation deleted managed binary"); assert(state,"empty operation lost running state");
assert(prerm_cleanup("remove"),"remove"); assert(length(calls)==1,"explicit remove did not clean binary");
restore_ok=false; assert(!prerm_cleanup("upgrade"),"DNS restoration failure swallowed");
restore_ok=true; stop_ok=false; calls=[]; assert(!prerm_cleanup("remove"),"stop failure swallowed"); assert(length(calls)==0,"deleted binary while service still running");
`);
NODE
failed=0
for test in "$WORK_DIR/"*.uc; do
  ucode "$test" || failed=1
done
[ "$failed" -eq 0 ]
printf 'DNS ownership and package preservation checks passed\n'
