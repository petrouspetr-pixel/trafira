#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
owner_pid=''
cleanup() {
  if [ -n "$owner_pid" ]; then kill "$owner_pid" 2>/dev/null || true; wait "$owner_pid" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export LOCK_TEST_DIR="$WORK_DIR"
mkdir -p "$TRAFIRA_RUNTIME_STATE_DIR"
chmod 755 "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$WORK_DIR/child.uc" <<'UC'
let lock=require("service.operation_lock");
let held=lock.acquire("child");
assert(held,"nested child may borrow the owner's lock");
lock.release(held);
UC
cat >"$WORK_DIR/owner.uc" <<'UC'
let fs=require("fs"),lock=require("service.operation_lock");
let held=lock.acquire("owner");
assert(held,"owner acquires lock");
assert(!lock.acquire("independent-worker",false),"asynchronous worker cannot borrow a parent's lock");
assert(system("ucode -L \"$TRAFIRA_LIB\" \"$LOCK_TEST_DIR/child.uc\"")==0,"nested command succeeds");
fs.writefile(getenv("LOCK_TEST_DIR")+"/ready","1");
system("sleep 10");
lock.release(held);
UC
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/owner.uc" &
owner_pid=$!
for _ in $(seq 1 50); do
  [ ! -f "$WORK_DIR/ready" ] || break
  kill -0 "$owner_pid" 2>/dev/null || { wait "$owner_pid"; exit 1; }
  sleep 0.1
done
test -f "$WORK_DIR/ready"
test "$(stat -c %a "$TRAFIRA_RUNTIME_STATE_DIR")" = 755
ucode -L "$TRAFIRA_LIB" -e 'let l=require("service.operation_lock"); assert(!l.acquire("competitor"),"unrelated worker must be busy");'
for entry in 'service/lifecycle.uc start' 'service/initd.uc start-service' 'components/action.uc component-action'; do
  read -r module action <<<"$entry"
  if ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/$module" "$action" >"$WORK_DIR/entry.log" 2>&1; then
    echo "mutation accepted while configuration operation is locked: $entry" >&2
    exit 1
  fi
  grep -q 'configuration operation is already running' "$WORK_DIR/entry.log"
done
inode=$(stat -c %i "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock")
kill -KILL "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
owner_pid=''
# A subprocess still sleeps, but close-on-exec prevents it retaining the lock.
ucode -L "$TRAFIRA_LIB" -e 'let l=require("service.operation_lock"); let h=l.acquire("after-death"); assert(h,"dead owner releases kernel lock"); l.release(h);'
test "$(stat -c %i "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock")" = "$inode"
printf 'operation lock checks passed\n'
