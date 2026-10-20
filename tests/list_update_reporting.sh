#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TEST_DIR="$WORK_DIR" TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/cache"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
mode=$(cat "$TEST_DIR/mode")
case "$mode" in timeout) exit 28;; http) printf 429; exit 22;; oversized) exit 63;; esac
while [ "$#" -gt 0 ]; do
 if [ "$1" = --output ]; then
  case "$mode" in invalid) printf 'invalid HTML' >"$2";; empty) : >"$2";; changed) printf 'valid-rules-changed' >"$2";; *) printf 'valid-rules-new' >"$2";; esac
  exit 0
 fi
 shift
done
exit 1
SH
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
grep -q '^valid-rules' "$3" || exit 1
/bin/cp "$3" "$5"
SH
cat >"$WORK_DIR/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [ -f "$TEST_DIR/low-space" ]; then printf 'test 10000 9000 1000 90%% /\n'; else printf 'test 100000 1000 99000 1%% /\n'; fi
SH
cat >"$WORK_DIR/bin/cp" <<'SH'
#!/bin/sh
[ ! -f "$TEST_DIR/write-fail" ] || exit 1
exec /bin/cp "$@"
SH
cat >"$WORK_DIR/bin/mktemp" <<'SH'
#!/bin/sh
case "$1" in "$TRAFIRA_RULESET_CACHE_DIR"/*) exec /bin/mktemp "$@";; *) exec /bin/mktemp "$TEST_DIR/transient.XXXXXX";; esac
SH
chmod +x "$WORK_DIR/bin/"*
cat >"$WORK_DIR/check.uc" <<'UC'
let fs=require("fs"),cache=require("singbox.ruleset_cache"),root=ARGV[0];
function check(ok,message) { if(!ok)die(message+"\n"); }
let rule={type:"remote",tag:"safe-list",url:"https://user:password@example.org/private?token=hidden",format:"binary",http_client:{}};
let config={route:{rule_set:[rule]}},events=[];
function capture(event){push(events,event);}
fs.writefile(root+"/mode","timeout");
check(!cache.refresh(config,"",capture),"timeout fails");
check(length(events)==1,"failed refresh emits one structured diagnostic");
check(events[0].tag=="safe-list" && events[0].stage=="download" && events[0].reason=="download_timeout" && events[0].code==28,"timeout reason and exit code");
check(events[0].previous_snapshot=="missing","missing previous snapshot is explicit");
let input=root+"/input";fs.writefile(input,"valid-rules-old");
check(cache.save(rule,input),"seed old copy");let saved=cache.path(rule);
events=[];check(!cache.refresh(config,"",capture),"second timeout fails");
check(events[0].previous_snapshot=="kept" && fs.readfile(saved)=="valid-rules-old","timeout keeps old bytes");
for(let mode in ["http","invalid"]){
 events=[];fs.writefile(root+"/mode",mode);check(!cache.refresh(config,"",capture),"reject failed replacement");
 check(events[0].reason==(mode=="http"?"http_error":"invalid_rule_set"),"distinguish HTTP and validation failures");
 check(events[0].previous_snapshot=="kept" && fs.readfile(saved)=="valid-rules-old","failed replacement preserves old copy");
 if(mode=="http")check(events[0].http_status==429,"HTTP status is retained without URLs");
 if(mode=="invalid")check(events[0].stage=="validation","validation stage is explicit");
}
fs.writefile(root+"/mode","valid");fs.writefile(root+"/low-space","1");events=[];
check(!cache.refresh(config,"",capture) && events[0].reason=="insufficient_space" && events[0].stage=="storage","storage reserve reason");
fs.unlink(root+"/low-space");fs.writefile(root+"/write-fail","1");events=[];
check(!cache.refresh(config,"",capture) && events[0].reason=="write_failed","write failure reason");
check(fs.readfile(saved)=="valid-rules-old","write failure keeps old copy");
fs.unlink(root+"/write-fail");events=[];
check(cache.refresh(config,"",capture) && length(events)==0,"successful update emits no failure");
check(fs.readfile(saved)=="valid-rules-new","valid update still publishes");
fs.writefile(root+"/mode","timeout");events=[];
let second={type:"remote",tag:"second-list",url:"https://example.org/second",format:"binary",http_client:{}};
check(!cache.refresh({route:{rule_set:[rule,second]}},"",capture) && length(events)==2,"report every failed list and continue");
check(index(sprintf("%J",events),"password")<0 && index(sprintf("%J",events),"hidden")<0 && index(sprintf("%J",events),"https:")<0,"diagnostics exclude URLs and credentials");
for(let mode in ["oversized","empty"]){
 events=[];fs.writefile(root+"/mode",mode);check(!cache.refresh(config,"",capture),"reject oversized and empty responses");
 check(events[0].reason==(mode=="oversized"?"file_size_limit":"empty_download"),"size and empty response reasons");
}
fs.writefile(root+"/mode","changed");
system("head -c 8388608 /dev/zero >"+root+"/cache/filler");events=[];
check(!cache.refresh(config,"",capture) && events[0].reason=="cache_quota_exceeded" && fs.readfile(saved)=="valid-rules-new","quota failure keeps previous snapshot");
fs.unlink(root+"/cache/filler");
fs.unlink(root+"/cache/.cache.lock");fs.mkdir(root+"/cache/.cache.lock",0700);events=[];
check(!cache.refresh(config,"",capture) && events[0].reason=="cache_lock_failed" && events[0].previous_snapshot=="kept","lock failure is reported without claiming a missing copy");
fs.rmdir(root+"/cache/.cache.lock");
fs.writefile(root+"/mode","timeout");rule.tag="https://user:password@example.org/?token=hidden";events=[];
check(!cache.refresh(config,"",capture) && events[0].tag=="custom-list","URL-shaped tags are redacted");
for(let name in fs.lsdir(root))check(index(name,"transient.")!=0,"all temporary downloads and checks removed");
print("List refresh failure diagnostics and retained snapshots passed\n");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/check.uc" "$WORK_DIR"
node - "$ROOT_DIR" "$WORK_DIR" <<'JS'
const fs=require('fs'),root=process.argv[2],dir=process.argv[3];
const source=fs.readFileSync(`${root}/trafira/files/usr/lib/components/updates.uc`,'utf8');
function extract(name){const start=source.indexOf(`function ${name}(`);if(start<0)throw Error(`Missing ${name}`);return source.slice(start,source.indexOf('\n}\n',start)+3);}
const prefix=`
let messages=[],order=[],writes=0,fail="",throw_at="",cache_fail=false,dns_ok=true;
function check(ok,message){if(!ok)die(message+"\\n");}
function reset(){messages=[];order=[];writes=0;fail="";throw_at="";cache_fail=false;dns_ok=true;}
function command_success_from_args(args){if(args[0]=="logger"){let fields=match(args[3],/^\\[([^\\]]+)\\] (.*)$/);push(messages,{text:fields[2],level:fields[1]});return true;}if(args[0]=="sleep")return true;return system(command_from_args(args)+" >/dev/null 2>&1")==0;}
function section_name(section){return section[".name"];}
function list_option_values(section,kind){return section[kind]||[];}
let connections={rule_sets_with_subnets:function(section){return section.refs||[];}};
function uci_settings(){return {};}
function service_proxy_address(settings,kind){return "";}
function dns_probe_passed(proxy){return dns_ok;}
function github_probe(proxy){return true;}
function uci_sections(kind){return [{".name":"one"},{".name":"two"}];}
function read_json_file(path){return {};}
function option(settings,name,fallback){return fallback;}
function write_list_update_timestamp(timestamp){writes++;}
function now_seconds(){return 123;}
function operation(name){return function(section,settings){let key=name+":"+section_name(section);push(order,key);if(key==throw_at)die("internal secret");return key!=fail;};}
let rebuild_domain_ip_lists_from_rule=operation("domain_ip"),import_builtin_subnets_from_rule=operation("builtin_subnets"),import_domains_from_remote_domain_lists=operation("remote_domains"),import_subnets_from_remote_subnet_lists=operation("remote_subnets"),import_rule_sets_with_subnets_from_rule=operation("ruleset_subnets");
let startup_cache_stub={refresh:function(config,proxy,report){if(cache_fail)report({tag:"failed-list",stage:"download",reason:"download_timeout",code:28,previous_snapshot:"kept"});return !cache_fail;}};
`;
const suffix=`
check(list_reference_label({".name":"one",remote_domain_lists:["first","second"]},"remote_domain_lists","second")=="section=one list=remote_domain_lists[2]","identify the configured list by position without its URL");
check(list_reference_label({".name":"one",refs:["private-url"]},"ruleset_subnets","private-url")=="section=one list=ruleset_subnets[1]","identify custom subnet rule sets");
reset();require("fs").writefile(getenv("TEST_DIR")+"/mode","http");
check(!download_to_file("https://user:password@example.org/private?token=hidden",getenv("TEST_DIR")+"/transport","127.0.0.1:4535","section=one list=remote_domain_lists[1]"),"failed remote list download");
check(index(sprintf("%J",messages),"password")<0 && index(sprintf("%J",messages),"hidden")<0,"remote list download errors must not leak source secrets");
check(length(messages)==3 && index(messages[0].text,"http=429")>=0 && index(messages[0].text,"section=one list=remote_domain_lists[1]")>=0,"ordinary downloads identify list, HTTP status and retries");
reset();

check(list_update_pass(),"successful pass");check(writes==1 && messages[length(messages)-1].level=="info","success updates timestamp once");
check(join("|",order)=="domain_ip:one|domain_ip:two|builtin_subnets:one|builtin_subnets:two|remote_domains:one|remote_domains:two|remote_subnets:one|remote_subnets:two|ruleset_subnets:one|ruleset_subnets:two","preserve stage and section order");
reset();fail="builtin_subnets:two";
check(!list_update_pass() && writes==0 && length(order)==10,"failure still runs later stages without success timestamp");
check(index(sprintf("%J",messages),"section=two stage=builtin_subnets reason=operation_failed")>=0 && messages[length(messages)-1].level=="error","failed section and stage reach error summary");
reset();throw_at="remote_subnets:one";
check(!list_update_pass() && length(order)==10 && writes==0,"stage exception does not hide later results");
check(index(sprintf("%J",messages),"reason=internal_error")>=0 && index(sprintf("%J",messages),"internal secret")<0,"exception text is not logged");
reset();cache_fail=true;
check(!list_update_pass() && writes==0,"cache failure prevents successful timestamp");
check(index(sprintf("%J",messages),"list=failed-list stage=download reason=download_timeout exit=28; previous snapshot file kept")>=0,"cache callback reaches logger");
reset();dns_ok=false;check(!list_update_pass() && length(order)==0 && messages[length(messages)-1].level=="error","DNS failure logs stage without modifying lists");
print("List update stage order, error severity and timestamp tests passed\\n");
`;
fs.writeFileSync(`${dir}/stages.uc`,extract('as_string')+extract('shell_quote')+extract('command_from_args')+prefix+extract('safe_list_log_text')+extract('log_message')+extract('list_reference_label')+extract('download_to_file')+extract('log_list_refresh_failure')+extract('run_list_update_stage')+extract('list_update_pass').replace('require("singbox.ruleset_cache")','startup_cache_stub')+suffix);
JS
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/stages.uc"
