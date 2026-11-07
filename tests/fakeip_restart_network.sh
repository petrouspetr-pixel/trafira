#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_TRAFIRA_NETWORK_TESTS:-0}" != 1 ]; then
  echo 'FakeIP restart/QUIC kernel checks run in isolated network CI'
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "$ROOT_DIR/tests/helpers/fakeip_restart_network.py"
