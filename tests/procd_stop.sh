#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR" "$WORK_DIR/sing-box" <<'JS'
const fs=require('fs'),vm=require('vm');
const src=fs.readFileSync(process.argv[2]+'/trafira/files/usr/lib/singbox/runtime.uc','utf8');
const body=src.split('function managed_service_text() {')[1].split('\n}\n')[0];
const text=vm.runInNewContext('(function(){'+body+'})()',{SB_MANAGED_SERVICE_MARKER:'test-managed'});
fs.writeFileSync(process.argv[3],text);
JS
for init in "$ROOT_DIR/trafira/files/etc/init.d/trafira" "$WORK_DIR/sing-box"; do
  for mode in present absent denied disconnected; do
    for backend_status in 0 7; do
      [ "$init" != "$WORK_DIR/sing-box" ] || [ "$backend_status" = 0 ] || continue
      set +e
      (
        initscript="$init"
        # shellcheck source=/dev/null
        . "$init"
        TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
        initd_ucode() { return "$backend_status"; }
        JSON_PREFIX=original
        json_set_namespace() { local old="$JSON_PREFIX"; JSON_PREFIX="$1"; [ -z "${2:-}" ] || printf -v "$2" '%s' "$old"; return 0; }
        json_init() { TEST_JSON=; }
        json_add_string() { TEST_JSON="${TEST_JSON}|$1=$2"; }
        json_dump() { printf '%s' "$TEST_JSON"; }
        json_cleanup() { :; }
        ubus() {
          if [ "$3" = list ]; then [ "$mode" != disconnected ]; return; fi
          printf '%s' "$4" >"$WORK_DIR/payload"
          case "$mode" in
            present) return 0 ;;
            absent|disconnected) echo 'Command failed: Not found' >&2; return 4 ;;
            denied) echo 'Command failed: Permission denied' >&2; return 6 ;;
          esac
        }
        procd_kill() { ubus call service delete '{}'; }
        stop_service
        procd_kill trafira instance
        result=$?
        if type service_stopped >/dev/null 2>&1; then service_stopped; result=$?; fi
        [ "$JSON_PREFIX" = original ] || { echo 'namespace was not restored' >&2; exit 9; }
        [ "$(cat "$WORK_DIR/payload")" = '|name=trafira|instance=instance' ] || { echo 'wrong delete payload' >&2; exit 9; }
        exit "$result"
      ) >"$WORK_DIR/out" 2>"$WORK_DIR/err"
      status=$?
      set -e
      if [ "$backend_status" = 7 ]; then
        [ "$status" = 7 ] || { echo 'backend stop error was hidden'; exit 1; }
      elif [ "$mode" = denied ]; then
        [ "$status" = 6 ] && grep -q 'Permission denied' "$WORK_DIR/err" || exit 1
      elif [ "$mode" = disconnected ]; then
        [ "$status" = 4 ] && grep -q 'Not found' "$WORK_DIR/err" || exit 1
      else
        [ "$status" = 0 ] && [ ! -s "$WORK_DIR/err" ] || { cat "$WORK_DIR/err"; echo "idempotent stop failed: $init/$mode"; exit 1; }
      fi
    done
  done
done
printf 'Idempotent procd stop preserves real backend and bus failures\n'
