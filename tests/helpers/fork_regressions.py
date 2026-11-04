"""Execute production ucode and generated configurations; never touch host UCI."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"


class ForkRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-fork-regression-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = {**os.environ, "TRAFIRA_LIB": str(LIB),
                    "TRAFIRA_RUNTIME_STATE_DIR": str(self.work / "runtime")}

    def run_ucode(self, args, **kwargs):
        return subprocess.run(["ucode", "-L", str(LIB), *args],
                              env=self.env, capture_output=True, text=True,
                              timeout=20, **kwargs)

    def generate(self, section=None, settings=None):
        fixture = {"settings": {"dns_server": ["1.1.1.1"],
                               "bootstrap_dns_server": ["9.9.9.9"], **(settings or {})},
                   "section": [section or {".name": "proxy", "action": "connection",
                               "outbound_jsons": ['{"type":"direct"}'], "ports": ["443", "8443"]}]}
        source = self.work / "fixture.json"
        output = self.work / "config.json"
        source.write_text(json.dumps(fixture))
        result = self.run_ucode([str(LIB / "singbox/generator.uc"), "generate-config-fixture",
                                 str(source), str(output), "127.0.0.1", "0", "1", "",
                                 "1.14.3-extended-2.7.3", "check-only"])
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(output.read_text())

    def test_subscription_invalid_base62_does_not_enter_generated_config(self):
        folder = self.work / "subscriptions"
        folder.mkdir()
        node = {"type": "vless", "server": "node.example", "server_port": 443,
                "uuid": "00000000-0000-4000-8000-000000000001"}
        nodes = []
        for tag, length, table in [("bad-four", "4-5", "Base62"), ("bad-five", "5", "Base62"),
                                    ("good-six", "6-8", "Base62"), ("unknown-format", "auto", "Base62"),
                                    ("other-table", "4", "Other"), ("good-range", "4-8", "Base62"),
                                    ("custom-alphabet", "13", "base62")]:
            nodes.append({**node, "tag": tag, "transport": {"type": "xhttp",
                          "session_id_table": table, "session_id_length": length}})
        nodes.append({**node, "tag": "normal"})
        original = json.dumps({"outbounds": nodes})
        (folder / "proxy-subscription-1.json").write_text(original)
        (folder / "proxy-subscription-1.url").write_text("https://subscription.example/test\n")
        (folder / "proxy-subscription-1.user_agent").write_text("")
        self.env["TMP_SUBSCRIPTION_FOLDER"] = str(folder)
        config = self.generate({".name": "proxy", "action": "connection",
                                "subscription_urls": ["https://subscription.example/test"]})
        tags = {o["tag"] for o in config["outbounds"]}
        self.assertNotIn("bad-four", tags, "invalid provider node must not break all other connections")
        self.assertNotIn("bad-five", tags)
        self.assertTrue({"normal", "good-six", "good-range", "custom-alphabet", "unknown-format", "other-table"} <= tags)
        self.assertEqual((folder / "proxy-subscription-1.json").read_text(), original)

    def test_blank_community_entries_do_not_reject_a_valid_section(self):
        source = self.work / "validator.json"
        source.write_text(json.dumps({"settings": {"dns_server": ["1.1.1.1"],
                          "bootstrap_dns_server": ["9.9.9.9"]}, "section": [{".name": "bypass",
                          "action": "bypass", "community_lists": ["", "  ", " youtube "]}]}))
        self.env["COMMUNITY_SERVICES"] = "youtube"
        result = self.run_ucode([str(LIB / "config/validator.uc"), "validate-runtime-fixture",
                                str(source), "{}"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_ucode(["-e", 'let c=require("config.connections");'
            'let v=c.community_lists({community_lists:[""," youtube "," "]});'
            'assert(length(v)==1 && v[0]=="youtube", "normalized community values");'])
        self.assertEqual(result.returncode, 0, result.stderr)
        source.write_text(source.read_text().replace(" youtube ", "unknown"))
        result = self.run_ucode([str(LIB / "config/validator.uc"), "validate-runtime-fixture", str(source), "{}"])
        self.assertNotEqual(result.returncode, 0, "unknown nonempty service must remain rejected")

    def test_direct_probe_cannot_be_selected_by_a_user_section(self):
        for router in [False, True]:
            with self.subTest(router=router):
                config = self.generate(settings={"router_origin_enabled": "1" if router else "0",
                                                 "router_origin_section": "proxy"})
                # The first matching terminal rule is what decides the route. The
                # section deliberately includes the diagnostic service's port.
                for inbound in (["tproxy-in", "router-tproxy-in"] if router else ["tproxy-in"]):
                    matching = []
                    for rule in config["route"]["rules"]:
                        if rule.get("action") != "route":
                            continue
                        if rule.get("inbound") and inbound not in as_list(rule["inbound"]):
                            continue
                        if rule.get("domain") and "fakeip.podkop.fyi" not in as_list(rule["domain"]):
                            continue
                        if rule.get("domain_suffix") or rule.get("rule_set"):
                            continue
                        matching.append(rule)
                    self.assertTrue(matching)
                    self.assertEqual(matching[0].get("outbound"), "direct-out", inbound)
                    self.assertEqual(matching[0].get("override_port"), 8443)
                control = next(r for r in config["route"]["rules"]
                               if r.get("domain") == "ip.podkop.fyi" and r.get("action") == "route")
                self.assertEqual(control["outbound"], "proxy-out", "the proxy control must stay proxied")

    def test_fakeip_ipv6_is_not_ula_and_all_default_ranges_agree(self):
        config = self.generate()
        fake = next(s for s in config["dns"]["servers"] if s["type"] == "fakeip")
        network = ipaddress.ip_network(fake["inet6_range"])
        self.assertFalse(network.overlaps(ipaddress.ip_network("fc00::/7")),
                         "Chromium classifies ULA FakeIP as local-network access")
        self.assertEqual(str(network), "2001:2::/112")
        result = self.run_ucode([str(LIB / "core/constants.uc"), "get", "SB_FAKEIP_INET6_RANGE"])
        self.assertEqual(result.stdout.strip(), str(network))
        result = self.run_ucode(["-e", 'let t=require("singbox.constants"),d=require("diagnostics.route_dns");'
            'assert(t.FAKEIP_INET6_RANGE=="2001:2::/112","same range");'
            'assert(d.fake({dns:{servers:[{type:"fakeip"}]}},"2001:2::1"),"new default recognized");'
            'assert(d.fake({dns:{servers:[{type:"fakeip",inet6_range:"fc00::/18"}]}},"fc00::1"),"explicit old running config still recognized");'])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dynamic_ech_has_only_an_exact_dns_exception(self):
        for static in [False, True]:
            with self.subTest(static=static):
                ech = {"enabled": True, "query_server_name": "ech.example"}
                if static:
                    ech["config"] = ["-----BEGIN ECH CONFIGS-----\nfixture\n-----END ECH CONFIGS-----"]
                node = {"type": "http", "server": "127.0.0.1", "server_port": 8443,
                        "tls": {"enabled": True, "server_name": "target.example", "ech": ech}}
                config = self.generate({".name": "proxy", "action": "connection",
                                        "outbound_jsons": [json.dumps(node)]})
                matches = [r for r in config["dns"]["rules"]
                           if r.get("query_type") == "HTTPS" and r.get("action") == "route"
                           and "ech.example" in as_list(r.get("domain", []))]
                self.assertEqual(len(matches), 0 if static else 1)
                reject = next(i for i, r in enumerate(config["dns"]["rules"])
                              if r.get("query_type") == "HTTPS" and r.get("action") == "reject")
                if matches:
                    self.assertLess(config["dns"]["rules"].index(matches[0]), reject)
                    self.assertNotIn("domain_suffix", matches[0], "no broad client DNS exception")
                    self.assertEqual(matches[0]["server"], "bootstrap-dns-server",
                                     "ECH setup must not depend on the same TLS tunnel")

    def test_monitoring_requests_have_a_bounded_transport_and_report_failure(self):
        state = self.work / "uci"
        state.write_text("trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n")
        self.env["TRAFIRA_UCI_STATE_FILE"] = str(state)
        folder = self.work / "bin"
        folder.mkdir()
        curl = folder / "curl"
        curl.write_text('#!/usr/bin/env python3\nimport sys,json\n'
                        'a=sys.argv[1:]\n'
                        'assert "--max-time" in a, "missing transport deadline"\n'
                        'assert 0<float(a[a.index("--max-time")+1])<=5\n'
                        'assert "--fail" in a, "HTTP errors must not masquerade as data"\n'
                        'print(json.dumps({"connections":[],"proxies":{}}))\n')
        curl.chmod(0o755)
        self.env["PATH"] = str(folder) + os.pathsep + os.environ["PATH"]
        for action in ["get_connections", "get_proxies"]:
            with self.subTest(action=action):
                result = self.run_ucode([str(LIB / "diagnostics/runtime.uc"), "clash-api", action])
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertIn("connections" if action == "get_connections" else "proxies", payload)
        curl.write_text('#!/bin/sh\nexit 28\n')
        result = self.run_ucode([str(LIB / "diagnostics/runtime.uc"), "clash-api", "get_connections"])
        self.assertNotEqual(result.returncode, 0, "transport failure must be an error, not a successful empty list")
        self.assertIn("error", json.loads(result.stdout))


def as_list(value):
    return value if isinstance(value, list) else [value]


if __name__ == "__main__":
    unittest.main(verbosity=2)
