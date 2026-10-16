#!/usr/bin/env bash
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
owner_pid=''
cleanup() {
  if [ -n "$owner_pid" ]; then kill "$owner_pid" 2>/dev/null || true; wait "$owner_pid" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
export TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TRAFIRA_CONFIG_NAME=retry_test
export RETRY_TEST_DIR="$WORK_DIR"
mkdir -p "$WORK_DIR/bin" "$TRAFIRA_RUNTIME_STATE_DIR"
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RETRY_TEST_DIR/event"
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK_DIR/bin/ubus" "$WORK_DIR/bin/logger"
export PATH="$WORK_DIR/bin:$PATH"
cat >"$WORK_DIR/owner.uc" <<'UC'
let lock=require("service.operation_lock").acquire("fixture");
assert(lock,"fixture owns the configuration lock");
require("fs").writefile(getenv("RETRY_TEST_DIR")+"/ready","1");
sleep(30000);
UC
ucode -L "$TRAFIRA_LIB" "$WORK_DIR/owner.uc" &
owner_pid=$!
for _ in $(seq 1 100); do
  [ ! -f "$WORK_DIR/ready" ] || break
  sleep 0.05
done
test -f "$WORK_DIR/ready"
# A native config event must not disappear while another operation owns UCI.
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import fcntl, os, pathlib, subprocess
root = pathlib.Path(os.environ['RETRY_TEST_DIR'])
path = root / 'procd.lock'
descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
os.dup2(descriptor, 1000)
os.close(descriptor)
fcntl.flock(1000, fcntl.LOCK_EX)
lib = os.environ['TRAFIRA_LIB']
try:
    subprocess.run(['ucode', '-L', lib, lib+'/service/initd.uc',
                    'reload-service', 'on_config_change'], pass_fds=(1000,), check=True)
finally:
    os.close(1000)
# The deferred child is still sleeping. It must not retain procd's lock.
with path.open('r+') as probe:
    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
else
  ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/initd.uc" reload-service on_config_change >"$WORK_DIR/result" 2>&1
fi
for _ in $(seq 1 100); do
  [ ! -f "$WORK_DIR/event" ] || break
  sleep 0.05
done
test -f "$WORK_DIR/event"
grep -q '^call$' "$WORK_DIR/event"
grep -q '^service$' "$WORK_DIR/event"
grep -q '^event$' "$WORK_DIR/event"
ucode -e 'let lines=split(require("fs").readfile(getenv("RETRY_TEST_DIR")+"/event"),"\n"); let event=json(lines[3]); assert(event.type=="config.change" && event.data.package=="retry_test","retry targets the same config through procd");'
rm "$WORK_DIR/event"
# Manual operations keep their explicit busy failure; they must not auto-apply.
if ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/initd.uc" reload-service manual >"$WORK_DIR/result" 2>&1; then
  echo 'manual reload unexpectedly accepted while busy' >&2
  exit 1
fi
grep -q 'configuration operation is already running' "$WORK_DIR/result"
test ! -f "$WORK_DIR/event"
# Invalid lock storage is an error, not a busy operation to retry forever.
kill "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
owner_pid=''
rm "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
mkdir "$TRAFIRA_RUNTIME_STATE_DIR/operation.lock"
if ucode -L "$TRAFIRA_LIB" "$TRAFIRA_LIB/service/initd.uc" reload-service on_config_change >"$WORK_DIR/result" 2>&1; then
  echo 'invalid lock storage unexpectedly accepted' >&2
  exit 1
fi
test ! -f "$WORK_DIR/event"
printf 'initd config-change retry checks passed\n'
