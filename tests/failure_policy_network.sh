#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  printf 'Network policy tests run in the dedicated privileged CI job\n'
  exit 0
fi
[ "$(id -u)" = 0 ] || { echo 'Network test requires its isolated root CI job' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
router="trafira-fp-r-$$"
server="trafira-fp-s-$$"
cleanup() {
  for namespace in "$router" "$server"; do
    ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$namespace" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
ip netns add "$router"
ip netns add "$server"
ip link add veth-r type veth peer name veth-s
ip link set veth-r netns "$router"
ip link set veth-s netns "$server"
for namespace in "$router" "$server"; do ip -n "$namespace" link set lo up; done
ip -n "$router" addr add 198.51.100.1/24 dev veth-r
ip -n "$server" addr add 198.51.100.2/24 dev veth-s
ip -n "$router" -6 addr add 2001:db8:1::1/64 dev veth-r nodad
ip -n "$server" -6 addr add 2001:db8:1::2/64 dev veth-s nodad
ip -n "$router" link set veth-r up
ip -n "$server" link set veth-s up
ip netns exec "$server" python3 "$ROOT_DIR/tests/helpers/failure_policy_servers.py" http >"$WORK_DIR/http.log" 2>&1 &
ip netns exec "$server" python3 "$ROOT_DIR/tests/helpers/failure_policy_servers.py" 1080 >"$WORK_DIR/primary.log" 2>&1 &
primary_pid=$!
ip netns exec "$server" python3 "$ROOT_DIR/tests/helpers/failure_policy_servers.py" 1081 >"$WORK_DIR/reserve.log" 2>&1 &
reserve_pid=$!
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci" TRAFIRA_LIB="$WORK_DIR/lib" FAILURE_NETWORK_TEST="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR" "$TRAFIRA_LIB/service"
printf 'trafira.settings=settings\ntrafira.settings.config_path=%s/config.json\n' "$WORK_DIR" >"$TRAFIRA_UCI_STATE_FILE"
cat >"$WORK_DIR/service.sh" <<'SH'
#!/bin/sh
set -eu
directory=$FAILURE_NETWORK_TEST
case "$1" in
  sing-box-service-runtime-pid) cat "$directory/pid" 2>/dev/null || true ;;
  reload-sing-box-runtime)
    if [ -s "$directory/pid" ]; then kill "$(cat "$directory/pid")" 2>/dev/null || true; fi
    sleep 0.2
    sing-box run -c "$directory/config.json" </dev/null >"$directory/core.log" 2>&1 &
    echo $! >"$directory/pid"
    ;;
  wait-trafira-stable-start)
    sleep 0.4
    kill -0 "$(cat "$directory/pid")"
    ss -ltn | grep -q ':18000 '
    ;;
  *) exit 1 ;;
esac
SH
cat >"$TRAFIRA_LIB/service/state.uc" <<'UC'
let q=s=>"\x27"+replace(s,/\x27/g,"\x27\\\x27\x27")+"\x27";
exit(system("sh "+q(getenv("FAILURE_NETWORK_TEST")+"/service.sh")+" "+q(ARGV[0])));
UC
cat >"$WORK_DIR/driver.uc" <<'UC'
let fs=require("fs"),s=require("singbox.failure_store"),t=require("singbox.failure_config"),a=require("service.failure_policy_apply");
let root=getenv("FAILURE_NETWORK_TEST"),path=root+"/config.json";
if(ARGV[0]=="init") {
 let sections=[{".name":"vpn",action:"connection",failure_policy:ARGV[1],failure_reserve_section:"reserve"}];
 let base={log:{level:"error"},inbounds:[{type:"mixed",tag:"protected",listen:"127.0.0.1",listen_port:18000}],
  outbounds:[{type:"socks",tag:"vpn-out",server:"198.51.100.2",server_port:1080,version:"5"},
   {type:"socks",tag:"reserve-out",server:"198.51.100.2",server_port:1081,version:"5"},
   {type:"direct",tag:"bypass-out"},{type:"direct",tag:"direct-out"}],
  route:{rules:[{action:"route",inbound:"protected",outbound:"vpn-out"}],final:"direct-out"},dns:{servers:[],rules:[]}};
 assert(s.write(path,t.apply(base,sections,{})) && s.save_base(path,base,sections));
} else if(ARGV[0]=="apply") {
 let result=a.apply("vpn",s.load(path).generation,ARGV[1]);
 assert(result.success,sprintf("%J",result));
} else if(ARGV[0]=="unguard")assert(a.clear_guard());
else if(ARGV[0]=="crash") {
 let stage=ARGV[1],base=s.load(path),pid=split(fs.readfile("/proc/self/stat")," ")[0];
 let candidate=t.apply(base.config,base.sections,{vpn:{mode:"blocked"}});
 let script=root+"/guard.nft";fs.writefile(script,a.guard_script([18000]));
 function die(name){if(stage==name)system("kill -9 "+pid);return true;}
 a.transition("test",{
  generation:()=>"test",prepare:()=>true,
  guard:()=>system("nft -f "+script)==0 && die("guard"),
  install:()=>s.write(path,candidate) && die("install"),
  reload:()=>die("reload"),healthy:()=>die("healthy"),publish:()=>die("publish"),
  unguard:a.clear_guard,restore:()=>true
 });
}
UC
run() { ip netns exec "$router" ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/driver.uc" "$@"; }
service() { ip netns exec "$router" sh "$WORK_DIR/service.sh" "$1"; }
request() { ip netns exec "$router" curl --noproxy '' --proxy socks5h://127.0.0.1:18000 --max-time 2 -fsS "http://$1:18080/" >/dev/null 2>&1; }
blocked() { for address in 198.51.100.2 '[2001:db8:1::2]'; do if request "$address"; then echo 'Protected request escaped' >&2; exit 1; fi; done; }
working() { for address in 198.51.100.2 '[2001:db8:1::2]'; do request "$address"; done; }
no_direct() { ip netns exec "$router" nft -j list counters table inet audit | python3 -c 'import json,sys; counters=[x["counter"] for x in json.load(sys.stdin)["nftables"] if "counter" in x]; assert len(counters)==2 and all(c["packets"]==0 for c in counters),counters'; }
ip netns exec "$router" nft -f - <<'NFT'
table inet audit {
 counter direct4 {}
 counter direct6 {}
 chain output {
  type filter hook output priority 0; policy accept;
  ip daddr 198.51.100.2 tcp dport 18080 counter name direct4
  ip6 daddr 2001:db8:1::2 tcp dport 18080 counter name direct6
 }
}
NFT
sleep 0.5
run init reserve
service reload-sing-box-runtime
service wait-trafira-stable-start
blocked
run apply primary
working
kill "$primary_pid"
blocked
run apply reserve
working
kill "$reserve_pid"
run apply blocked
blocked
no_direct
for stage in guard install reload healthy publish; do
  run unguard
  run init block
  service reload-sing-box-runtime
  service wait-trafira-stable-start
  if run crash "$stage"; then echo "Crash hook did not fire: $stage" >&2; exit 1; fi
  ip netns exec "$router" nft list table inet TrafiraFailureGuard >/dev/null
  blocked
  no_direct
done
run unguard
run init direct
service reload-sing-box-runtime
service wait-trafira-stable-start
run apply direct
working
ip netns exec "$router" nft -j list counters table inet audit | python3 -c 'import json,sys; counters=[x["counter"] for x in json.load(sys.stdin)["nftables"] if "counter" in x]; assert len(counters)==2 and all(c["packets"]>0 for c in counters),counters'
printf 'IPv4/IPv6 primary, reserve, block, explicit direct and crash guards passed\n'
