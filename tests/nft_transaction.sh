#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
export NFT_CALLS="$WORK_DIR/calls" NFT_SCRIPT="$WORK_DIR/script" PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_CALLS"
test "$1" = -f && test "$2" = - || exit 2
cat >"$NFT_SCRIPT"
test ! -e "$NFT_SCRIPT.fail"
SH
chmod +x "$WORK_DIR/bin/nft"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),batch=require("nft.transaction");
let calls=getenv("NFT_CALLS"),script=getenv("NFT_SCRIPT"),published=0;
let t=batch.create();
assert(t.command(["delete","table","inet","Fixture"]),"queue replacement");
assert(t.command(["add","table","inet","Fixture"]),"queue new table");
assert(t.append("add chain inet Fixture route\n"),"append generated router rules");
t.after_commit(()=>{published++;});
assert(!fs.stat(calls),"building never changes live nftables");
assert(t.commit() && published==1,"successful commit publishes associated state");
assert(fs.readfile(script)=="delete table inet Fixture\nadd table inet Fixture\nadd chain inet Fixture route\n","order preserved exactly");
assert(fs.readfile(calls)=="-f -\n","one nft invocation for the transaction");
assert(!t.commit() && !t.command(["add","table","inet","Unexpected"]),"transaction cannot be reused");
fs.writefile(script+".fail","1");t=batch.create();t.command(["add","table","inet","Rejected"]);
t.after_commit(()=>{published++;});assert(!t.commit() && published==1,"nft error does not publish state");
fs.unlink(script+".fail");fs.unlink(calls);t=batch.create(32);
assert(!t.append("add table inet "+join("",map([1,2,3,4,5,6,7,8],()=>"oversized"))),"bounded transaction rejects overflow");
assert(!t.commit() && !fs.stat(calls),"overflow cannot apply a partial transaction");
t=batch.create();assert(t.commit() && !fs.stat(calls),"empty transaction is a no-op");
print("nft transaction ordering, bounds and failure checks passed\n");
'
