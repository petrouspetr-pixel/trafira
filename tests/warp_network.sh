#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_WARP_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'WARP packet tests require the dedicated isolated Linux CI job'
  exit 0
fi
[ "$(id -u)" = 0 ] || exit 1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/helpers/warp_network.py"
