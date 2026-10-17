#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime" GITHUB_LIMIT_TEST="$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
set -eu
out= headers=
while [ "$#" -gt 0 ]; do
 case "$1" in -o|--output) shift; out=$1;; -D|--dump-header) shift; headers=$1;; esac
 shift
done
printf 'request\n' >>"$GITHUB_LIMIT_TEST/calls"
case "$(cat "$GITHUB_LIMIT_TEST/mode")" in
 limit) printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1600\r\n' >"$headers"; printf '{"message":"API rate limit exceeded"}' >"$out"; exit 22;;
 secondary) printf 'HTTP/2 403\r\nRetry-After: 120\r\n' >"$headers"; printf '{"message":"secondary rate limit"}' >"$out"; exit 22;;
 many) printf 'HTTP/2 429\r\nretry-after: 999999999\r\n' >"$headers"; printf '{}' >"$out"; exit 22;;
 forbidden) printf 'HTTP/2 403\r\n' >"$headers"; printf '{"message":"forbidden"}' >"$out"; exit 22;;
 ok) printf 'HTTP/2 200\r\n' >"$headers"; printf '{"ok":true}' >"$out";;
esac
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH"
printf limit >"$WORK_DIR/mode"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),api=require("components.github_api"),root=getenv("GITHUB_LIMIT_TEST"),url="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=5&page=1";
let r=api.request(url,"",2097152,5,1000);
assert(!r.success && r.error=="github_rate_limited" && r.retry_at==1600,"403 exposes reset time");
assert(api.request(url,"",2097152,5,1001).retry_at==1600,"explicit refresh respects cooldown");
assert(length(filter(split(trim(fs.readfile(root+"/calls")),"\n"),(s)=>length(s)>0))==1,"cooldown makes no network request");
fs.writefile(root+"/mode","ok");
assert(api.request(url,"",2097152,5,1601).success,"network resumes after reset");
fs.writefile(root+"/mode","forbidden");
assert(api.request(url,"",2097152,5,1700).error!="github_rate_limited","ordinary 403 is not a rate limit");
fs.writefile(root+"/mode","secondary");
assert(api.request(url,"",2097152,5,1800).retry_at==1920,"secondary limit honors Retry-After");
fs.writefile(root+"/mode","many");
r=api.request(url,"",2097152,5,2000);
assert(r.retry_at==5600,"untrusted retry period is bounded to one hour");
assert(!api.request("https://other.example/repos/a/b/releases","",2097152,5,6000).success,"API helper does not fetch arbitrary hosts");
print("GitHub API cooldown and recovery checks passed\n");
'
