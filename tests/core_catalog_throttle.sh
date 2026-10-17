#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export TRAFIRA_CORE_CATALOG_DIR="$WORK_DIR/catalog"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let c=require("components.core_catalog"),env={variant:"stable",architecture:"aarch64",package_type:"apk"};
let item={version:"1.14.1-r1",variant:"stable",architecture:"aarch64",package_type:"apk",stable:true,repository_package:"sing-box"};
assert(c.load(env,false,()=>[item],1000).success,"seed catalog");
let result=c.load(env,true,()=>({error:"github_rate_limited",retry_at:2200}),1900);
assert(!result.success && result.error=="github_rate_limited" && result.retry_at==2200,"preserve rate limit and retry time");
assert(result.entries[0].version==item.version && !result.entries[0].available,"stale versions display only");
assert(c.resolve("stable~aarch64~apk~1.14.1-r1",env,()=>({error:"github_rate_limited",retry_at:2200}))==null,"install cannot resolve stale metadata");
assert(c.load(env,true,()=>[item],2201).success,"fresh metadata recovers after limit");
print("rate-limited catalog checks passed\n");
'
