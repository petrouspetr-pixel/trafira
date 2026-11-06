#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
cleanup() {
  # Release a blocked copy even when an assertion fails, then remove our fixture.
  touch "$WORK_DIR/release" 2>/dev/null || true
  if [ -n "${first:-}" ]; then wait "$first" 2>/dev/null || true; fi
  if [ -n "${second:-}" ]; then wait "$second" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/cache"
export ORPHAN_CACHE_TEST="$WORK_DIR"
export ORPHAN_CACHE_REAL_CP
ORPHAN_CACHE_REAL_CP="$(command -v cp)"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RULESET_CACHE_DIR"
# Only the core parser and physical free-space probe are substituted. Cache
# locking, quota calculation, staging, copying, renaming and hashes are real.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/sing-box"
cat >"$WORK_DIR/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1048576 0 1048576 0%% /\n'
SH
cat >"$WORK_DIR/bin/cp" <<'SH'
#!/bin/sh
"$ORPHAN_CACHE_REAL_CP" "$@" || exit $?
if [ "${ORPHAN_CACHE_BLOCK_COPY:-0}" = 1 ]; then
  touch "$ORPHAN_CACHE_TEST/copy-ready"
  while [ ! -e "$ORPHAN_CACHE_TEST/release" ]; do sleep 0.02; done
fi
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
python3 - "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, byte in [('old', b'o'), ('new', b'n')]:
    (root / name).write_bytes(byte * (4 * 1024 * 1024))
PY
old_path=$(ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e 'let c=require("singbox.ruleset_cache");print(c.path({type:"remote",url:"https://example.invalid/old.srs",format:"binary"}));')
"$ORPHAN_CACHE_REAL_CP" "$WORK_DIR/old" "$old_path"
"$ORPHAN_CACHE_REAL_CP" "$WORK_DIR/old" "$TRAFIRA_RULESET_CACHE_DIR/.stage.A1b2C3"
# The orphan is deliberately fresh: ownership of the cache lock, rather than an
# age heuristic, proves no cooperating writer is still using a reserved stage.
: >"$TRAFIRA_RULESET_CACHE_DIR/.stage.foreign-note"
mkdir "$TRAFIRA_RULESET_CACHE_DIR/.stage.D4e5F6"
printf 'foreign target\n' >"$WORK_DIR/foreign-target"
ln -s "$WORK_DIR/foreign-target" "$TRAFIRA_RULESET_CACHE_DIR/.stage.G7h8I9"
: >"$TRAFIRA_RULESET_CACHE_DIR/.cache.lock"
lock_inode=$(stat -c %i "$TRAFIRA_RULESET_CACHE_DIR/.cache.lock")
cat >"$WORK_DIR/save.uc" <<'UC'
let fs=require("fs"),cache=require("singbox.ruleset_cache"),root=getenv("ORPHAN_CACHE_TEST");
let rule={type:"remote",url:ARGV[0],format:"binary"},diagnostic={};
assert(cache.save(rule,root+"/new",null,diagnostic),"orphan staging must not block a final 8 MiB cache: "+sprintf("%J",diagnostic));
assert(fs.stat(cache.path(rule)).size==4194304,"new snapshot bytes published");
UC
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/save.uc" https://example.invalid/new.srs
test ! -e "$TRAFIRA_RULESET_CACHE_DIR/.stage.A1b2C3"
cmp "$WORK_DIR/old" "$old_path"
test -f "$TRAFIRA_RULESET_CACHE_DIR/.stage.foreign-note"
test -d "$TRAFIRA_RULESET_CACHE_DIR/.stage.D4e5F6"
test -L "$TRAFIRA_RULESET_CACHE_DIR/.stage.G7h8I9"
test "$(cat "$WORK_DIR/foreign-target")" = 'foreign target'
test "$(stat -c %i "$TRAFIRA_RULESET_CACHE_DIR/.cache.lock")" = "$lock_inode"
printf 'orphan quota recovery and foreign entries checks passed\n'

# Even a reserved staging name may be the caller's source. Validation must not
# be followed by deleting that input. No managed production caller needs this
# arrangement, but preserving it prevents a destructive cleanup edge case.
"$ORPHAN_CACHE_REAL_CP" "$WORK_DIR/old" "$TRAFIRA_RULESET_CACHE_DIR/.stage.SourcE"
ln "$TRAFIRA_RULESET_CACHE_DIR/.stage.SourcE" "$WORK_DIR/source-hardlink"
ucode -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),cache=require("singbox.ruleset_cache"),root=getenv("ORPHAN_CACHE_TEST");
let source=getenv("TRAFIRA_RULESET_CACHE_DIR")+"/.stage.SourcE",before=fs.readfile(source);
for (let input in [source,getenv("TRAFIRA_RULESET_CACHE_DIR")+"/../cache/.stage.SourcE",root+"/source-hardlink"]) {
    let diagnostic={};
    cache.save({type:"remote",url:"https://example.invalid/source-guard.srs",format:"binary"},input,null,diagnostic);
    assert(fs.readfile(source)==before,"reserved staging input/alias/hardlink must not be deleted by orphan cleanup");
}
'
rm "$TRAFIRA_RULESET_CACHE_DIR/.stage.SourcE" "$WORK_DIR/source-hardlink"

# Deterministic unlink denial with actual ucode/cache I/O: instrument only the
# fs.unlink boundary in a copied production module, leaving locks and snapshots
# intact. Permissions alone are not reliable when the CI runner is root.
mkdir -p "$WORK_DIR/fault-lib/singbox"
python3 - "$ROOT_DIR" "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root / 'trafira/files/usr/lib/singbox/ruleset_cache.uc').read_text()
source = source.replace('fs.unlink(', 'fixture_unlink(')
source = source.replace('let fs = require("fs");', '''let fs = require("fs");
function fixture_unlink(path) {
    if (path == getenv("ORPHAN_UNLINK_DENIED")) return false;
    return fs.unlink(path);
}''', 1)
(work / 'fault-lib/singbox/ruleset_cache.uc').write_text(source)
PY
export ORPHAN_UNLINK_DENIED="$TRAFIRA_RULESET_CACHE_DIR/.stage.Denied"
"$ORPHAN_CACHE_REAL_CP" "$WORK_DIR/old" "$ORPHAN_UNLINK_DENIED"
ucode -L "$WORK_DIR/fault-lib" -L "$ROOT_DIR/trafira/files/usr/lib" -e '
let fs=require("fs"),cache=require("singbox.ruleset_cache"),root=getenv("ORPHAN_CACHE_TEST");
let rule={type:"remote",url:"https://example.invalid/new.srs",format:"binary"};
let target=cache.path(rule),before=fs.readfile(target),diagnostic={};
assert(!cache.save(rule,root+"/old",null,diagnostic),"unremovable orphan must fail safely");
assert(diagnostic.reason=="staging_cleanup_failed","orphan unlink failure must have a specific diagnostic: "+sprintf("%J",diagnostic));
assert(fs.readfile(target)==before,"failed orphan cleanup must preserve the prior valid snapshot");
assert(fs.stat(getenv("ORPHAN_UNLINK_DENIED")).size==4194304,"fault injection must retain denied file");
'
cmp "$WORK_DIR/old" "$old_path"
rm "$ORPHAN_UNLINK_DENIED"
printf 'staging source preservation and unlink failure checks passed\n'

# A live writer already holds this same stable lock while its staged copy is
# complete. A second save must wait; it must not remove the first writer's file.
export TRAFIRA_RULESET_CACHE_DIR="$WORK_DIR/concurrent-cache"
mkdir "$TRAFIRA_RULESET_CACHE_DIR"
ORPHAN_CACHE_BLOCK_COPY=1 ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/save.uc" https://example.invalid/first.srs &
first=$!
attempt=0
while [ ! -e "$WORK_DIR/copy-ready" ] && [ "$attempt" -lt 150 ]; do
  kill -0 "$first" || { echo 'FAIL: first writer exited before copying' >&2; exit 1; }
  sleep 0.02
  attempt=$((attempt + 1))
done
test -e "$WORK_DIR/copy-ready"
live_stage=$(find "$TRAFIRA_RULESET_CACHE_DIR" -maxdepth 1 -type f -name '.stage.*' -print)
test -n "$live_stage"
test "$(stat -c %s "$live_stage")" = 4194304
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/save.uc" https://example.invalid/second.srs &
second=$!
sleep 0.2
kill -0 "$second" || { echo 'FAIL: second writer did not wait for cache lock' >&2; exit 1; }
test -f "$live_stage"
test "$(stat -c %s "$live_stage")" = 4194304
touch "$WORK_DIR/release"
wait "$first"
wait "$second"
test ! -e "$live_stage"
test "$(find "$TRAFIRA_RULESET_CACHE_DIR" -maxdepth 1 -type f -name '*.snapshot' | wc -l)" -eq 2
printf 'live staging writer remains protected by stable cache lock\n'
