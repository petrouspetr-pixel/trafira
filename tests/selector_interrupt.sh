#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$WORK_DIR" <<'PYTEST'
import copy
import itertools
import json
import os
import pathlib
import subprocess
import sys
root = pathlib.Path(sys.argv[1])
lib = os.environ["TRAFIRA_LIB"]
for implementation, child in itertools.product(["watchdog", "native_fallback"], ["0", "1"]):
    reference = None
    signatures = {}
    for outer in [None, "0", "1"]:
        section = {".name": "demo", ".type": "section", "enabled": "1", "action": "connection",
                   "selector_proxy_links": ["vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha"]}
        if outer is not None:
            section["selector_interrupt_exist_connections"] = outer
        fixture = {"settings": {".name": "settings", ".type": "settings"},
                   "section": [section, {".name": "other", ".type": "section", "enabled": "1", "action": "connection", "outbound_jsons": ['{"type":"direct","tag":"Other"}']}],
                   "urltest": [{".name": "ut", ".type": "urltest", "section": "demo", "name": "URLTest", "interrupt_exist_connections": child}],
                   "priority_group": [{".name": "pg", ".type": "priority_group", "section": "demo", "name": "Main", "implementation": implementation, "interrupt_exist_connections": child}],
                   "priority_level": [{".name": "pl", ".type": "priority_level", "group": "pg", "name": "Primary", "order": "0", "regex": ["Alpha"]}]}
        case = root / f"{implementation}-{child}-{outer}"
        case.mkdir()
        source, output = case / "fixture.json", case / "config.json"
        source.write_text(json.dumps(fixture))
        pathlib.Path(str(output) + ".section-cache").mkdir()
        subprocess.run(["ucode", "-L", lib, lib + "/singbox/generator.uc", "generate-config-fixture", str(source), str(output), "127.0.0.1", "0", "1", "", "1.14.3", "check-only"], check=True)
        config = json.loads(output.read_text())
        outbounds = {item["tag"]: item for item in config["outbounds"]}
        assert outbounds["demo-out"]["interrupt_exist_connections"] is (outer != "0"), (implementation, child, outer)
        assert outbounds["other-out"]["interrupt_exist_connections"] is True, "unrelated section changed"
        assert outbounds["demo-urltest-ut-out"]["interrupt_exist_connections"] is (child == "1"), "child URLTest policy changed"
        priority = outbounds["demo-priority-pg-out"]
        if implementation == "watchdog":
            assert priority["interrupt_exist_connections"] is (child == "1"), "child Priority policy changed"
        else:
            assert priority["type"] == "fallback" and "interrupt_exist_connections" not in priority, "native fallback schema changed"
        if implementation == "watchdog" and child == "0":
            signatures[outer] = {
                kind: subprocess.check_output(["ucode", "-L", lib, lib + "/service/state.uc", kind + "-signature-fixture", str(source)], text=True).strip()
                for kind in ["sing-box", "nft", "list-update"]
            }
        comparable = copy.deepcopy(config)
        next(item for item in comparable["outbounds"] if item["tag"] == "demo-out")["interrupt_exist_connections"] = True
        if reference is None:
            reference = comparable
        assert comparable == reference, "selector policy changed routes, ordering or other generated settings"
    if signatures:
        assert signatures[None] == signatures["1"], "saving the existing default causes unnecessary runtime changes"
        assert signatures["0"]["sing-box"] != signatures[None]["sing-box"], "Apply would ignore the selector change"
        for kind in ["nft", "list-update"]:
            assert signatures["0"][kind] == signatures[None][kind], "selector change would needlessly rebuild firewall or download lists"
print("section selector defaults, explicit values and independent child policies passed")
PYTEST
