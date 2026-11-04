#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'Chromium address-space check runs in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
namespace="trafira-chromium-$$"
cleanup() {
  ip netns pids "$namespace" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$namespace" 2>/dev/null || true
}
trap cleanup EXIT
ip netns add "$namespace"
ip -n "$namespace" link set lo up
ip -n "$namespace" -6 addr add fc00::123/128 dev lo nodad
ip -n "$namespace" -6 addr add 2001:2::123/128 dev lo nodad
ip netns exec "$namespace" node "$ROOT_DIR/tests/helpers/fakeip_chromium.cjs"
