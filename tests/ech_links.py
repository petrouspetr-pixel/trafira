"""ECH URL import/export and generated DNS behavior, using production ucode."""
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from urllib.parse import quote, parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "trafira/files/usr/lib"
UUID = "00000000-0000-4000-8000-000000000001"


def vec(value):
    return struct.pack("!H", len(value)) + value


# An RFC 9849 ECHConfigList: X25519, HKDF-SHA256/AES-128-GCM, public name.
BODY = b"\x01\x00\x20" + vec(bytes(range(32))) + vec(b"\x00\x01\x00\x01")
BODY += b"\x00\x0e" + b"public.example" + vec(b"")
CONFIG = vec(b"\xfe\x0d" + vec(BODY))
B64 = base64.b64encode(CONFIG).decode()
PEM = "-----BEGIN ECH CONFIGS-----\n" + B64 + "\n-----END ECH CONFIGS-----\n"
DOH = "https://resolver.example:8443/custom-dns"


class ECHLinks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-ech-links-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = {**os.environ, "TRAFIRA_LIB": str(LIB),
                    "TRAFIRA_RUNTIME_STATE_DIR": str(self.work / "runtime")}

    def uc(self, *args):
        return subprocess.run(["ucode", "-L", str(LIB), *args], env=self.env,
                              text=True, capture_output=True, timeout=20)

    def link(self, ech, scheme="vless", security="tls", encoded=True):
        if scheme == "vmess":
            node = {"v": "2", "add": "node.example", "port": "443", "id": UUID,
                    "net": "tcp", "tls": "tls", "sni": "target.example", "alpn": "h2,http/1.1", "ech": ech}
            return "vmess://" + base64.b64encode(json.dumps(node).encode()).decode()
        auth = UUID if scheme == "vless" else "password"
        value = quote(ech, safe="") if encoded else ech
        return f"{scheme}://{auth}@node.example:443?security={security}&sni=target.example&alpn=h2%2Chttp%2F1.1&ech={value}#node"

    def parse(self, link):
        result = self.uc(str(LIB / "subscription/parser.uc"), "share-link-outbound", link, "node")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def serialize(self, node):
        source = self.work / "node.json"
        source.write_text(json.dumps(node))
        result = self.uc("-e", 'let fs=require("fs"),s=require("subscription.share_link");'
                         'print(s.serialize_outbound_link(json(fs.readfile(ARGV[0]))));', str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip(), "export must retain a usable ECH connection")
        return result.stdout.strip()

    def serialize_result(self, node):
        source = self.work / "raw-node.json"
        source.write_text(json.dumps(node))
        result = self.uc("-e", 'let fs=require("fs"),s=require("subscription.share_link");'
                         'print(s.serialize_outbound_link(json(fs.readfile(ARGV[0]))));', str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def generate_result(self, links=None, subscription=None):
        section = {".name": "proxy", "action": "connection", "domain_suffix": ["example.org"]}
        if subscription is not None:
            folder = self.work / "subscriptions"
            folder.mkdir(exist_ok=True)
            (folder / "proxy-subscription-1.json").write_text(json.dumps({"outbounds": subscription}))
            (folder / "proxy-subscription-1.url").write_text("https://subscription.example/test\n")
            (folder / "proxy-subscription-1.user_agent").write_text("")
            self.env["TMP_SUBSCRIPTION_FOLDER"] = str(folder)
            section["subscription_urls"] = ["https://subscription.example/test"]
        else:
            section["selector_proxy_links"] = links
        fixture = {"settings": {"dns_server": ["1.1.1.1"], "bootstrap_dns_server": ["9.9.9.9"],
                                "router_origin_enabled": "1", "router_origin_section": "proxy"},
                   "section": [section]}
        source, output = self.work / "fixture.json", self.work / "config.json"
        source.write_text(json.dumps(fixture))
        result = self.uc(str(LIB / "singbox/generator.uc"), "generate-config-fixture", str(source),
                         str(output), "127.0.0.1", "0", "1", "", "1.14.3-extended-2.7.3", "check-only")
        return result, json.loads(output.read_text()) if result.returncode == 0 else None

    def generate(self, **kwargs):
        result, config = self.generate_result(**kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if os.environ.get("TRAFIRA_REAL_ECH_CORE") == "1":
            checked = subprocess.run(["sing-box", "check", "-c", str(self.work / "config.json")],
                                     text=True, capture_output=True, timeout=15)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        for outbound in config["outbounds"]:
            self.assertFalse(any(k.startswith("__trafira_ech") for k in outbound), "internal ECH fields leaked")
            if "ech" in outbound.get("tls", {}):
                self.assertTrue(set(outbound["tls"]["ech"]) <=
                                {"enabled", "config", "config_path", "query_server_name"})
        return config

    def assert_static(self, node):
        self.assertTrue(node.get("tls", {}).get("enabled"), "TLS must remain enabled")
        self.assertEqual(node["tls"].get("server_name"), "target.example", "ECH must not replace the target SNI")
        self.assertEqual(node["tls"].get("alpn"), ["h2", "http/1.1"], "ECH roundtrip must preserve ALPN")
        ech = node["tls"].get("ech", {})
        self.assertTrue(ech.get("enabled"), "ECH must not disappear during import/export")
        pem = "\n".join(ech.get("config", []))
        self.assertIn("-----BEGIN ECH CONFIGS-----", pem)
        self.assertEqual(base64.b64decode(pem.split("-----")[2]), CONFIG)

    def test_inline_base64_and_pem_import_and_roundtrip(self):
        for scheme in ["vless", "trojan", "hysteria2", "vmess"]:
            for value in [B64, B64.rstrip("="), PEM]:
                with self.subTest(scheme=scheme, value=value[:20]):
                    node = self.parse(self.link(value, scheme))
                    self.assert_static(node)
                    self.assert_static(self.parse(self.serialize(node)))

    def test_standalone_parser_loads_ech_without_library_flags(self):
        env = {key: value for key, value in self.env.items() if key != "TRAFIRA_LIB"}
        result = subprocess.run(["ucode", str(LIB / "subscription/parser.uc"), "share-link-outbound",
                                 self.link(B64), "node"], env=env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_static(json.loads(result.stdout))

    def test_manual_and_subscription_inline_generation(self):
        for scheme in ["vless", "trojan", "hysteria2", "vmess"]:
            with self.subTest(scheme=scheme):
                link = self.link(B64, scheme)
                for args in [{"links": [link]}, {"subscription": [self.parse(link)]}]:
                    config = self.generate(**args)
                    self.assert_static(next(o for o in config["outbounds"] if o["type"] == scheme))

    def test_raw_static_pem_string_does_not_become_dynamic_during_export(self):
        node = {"type": "vless", "server": "node.example", "server_port": 443, "uuid": UUID,
                "tls": {"enabled": True, "server_name": "target.example", "alpn": ["h2", "http/1.1"],
                        "ech": {"enabled": True, "config": PEM}}}
        self.assert_static(self.parse(self.serialize(node)))

    def test_invalid_raw_static_config_is_not_exported_as_dynamic_ech(self):
        for config in ["invalid PEM", ["invalid PEM"], {"bad": "shape"}]:
            with self.subTest(config=config):
                node = {"type": "vless", "server": "node.example", "server_port": 443, "uuid": UUID,
                        "tls": {"enabled": True, "server_name": "target.example",
                                "ech": {"enabled": True, "config": config}}}
                self.assertEqual(self.serialize_result(node), "", "invalid inline ECH must not become dynamic")

    def test_explicit_doh_survives_roundtrip_and_both_generators(self):
        for encoded in [False, True]:
            link = self.link("ech.example+" + DOH, encoded=encoded)
            node = self.parse(link)
            exported = self.serialize(node)
            self.assertEqual(parse_qs(urlsplit(exported).query).get("ech"), ["ech.example+" + DOH])
            for args in [{"links": [link]}, {"subscription": [node]}]:
                config = self.generate(**args)
                outbound = next(o for o in config["outbounds"] if o["type"] == "vless")
                self.assertEqual(outbound["tls"]["ech"], {"enabled": True, "query_server_name": "ech.example"})
                rule = config["dns"]["rules"][0]
                self.assertEqual(rule.get("query_type"), "HTTPS")
                self.assertEqual(rule.get("domain"), ["ech.example"])
                self.assertEqual(rule.get("action"), "route")
                server = next(s for s in config["dns"]["servers"] if s["tag"] == rule["server"])
                self.assertEqual((server["type"], server["server"], server["server_port"], server["path"]),
                                 ("https", "resolver.example", 8443, "/custom-dns"))
                self.assertNotIn("detour", server, "default direct dialer must not use an empty outbound detour")
                self.assertEqual(server.get("domain_resolver"), "bootstrap-dns-server")

    def test_domain_only_uses_existing_exact_bootstrap_rule(self):
        node = self.parse(self.link("ech.example"))
        self.assertEqual(node["tls"].get("ech"), {"enabled": True, "query_server_name": "ech.example"})
        self.assertEqual(self.parse(self.serialize(node))["tls"]["ech"], node["tls"]["ech"])
        config = self.generate(links=[self.link("ech.example")])
        self.assertEqual(config["dns"]["rules"][0], {"query_type": "HTTPS", "domain": ["ech.example"],
                         "action": "route", "server": "bootstrap-dns-server"})

    def test_resolver_percent_path_and_ip_literals_are_preserved(self):
        for uri, host, port, path in [
                ("https://resolver.example/dns%2Fquery", "resolver.example", 443, "/dns%2Fquery"),
                ("https://192.0.2.53", "192.0.2.53", 443, "/dns-query"),
                ("https://[2001:db8::53]:8443/dns-query", "2001:db8::53", 8443, "/dns-query")]:
            with self.subTest(uri=uri):
                node = self.parse(self.link("ech.example+" + uri))
                self.assertEqual(parse_qs(urlsplit(self.serialize(node)).query).get("ech"), ["ech.example+" + uri])
                config = self.generate(links=[self.link("ech.example+" + uri)])
                server = next(s for s in config["dns"]["servers"] if s["tag"] == config["dns"]["rules"][0]["server"])
                self.assertEqual((server["server"], server["server_port"], server["path"]), (host, port, path))
                self.assertNotIn("detour", server, "default dialer connects directly")
                if host != "resolver.example":
                    self.assertNotIn("domain_resolver", server, "literal resolver address must not need bootstrap")

    def test_invalid_ech_rejects_connection_instead_of_downgrading_tls(self):
        malformed = ["", "not base64!", "AA==", "AAAA", B64[:-5],
                     "-----BEGIN CERTIFICATE-----\n" + B64 + "\n-----END CERTIFICATE-----",
                     "ech.example+http://resolver.example/dns-query", "ech.example+https:///missing-host",
                     "ech.example+https://user:secret@resolver.example/dns-query",
                     "ech.example+https://resolver.example:99999/dns-query",
                     "ech.example+https://resolver.example/dns-query?profile=private",
                     "ech.example+https://resolver.example/dns-query#fragment", "bad..example",
                     "A" * 90000]
        for value in malformed:
            with self.subTest(value=value[:30]):
                link = self.link(value)
                # File input also exercises the streaming subscription parser without argv limits.
                source, output = self.work / "invalid.txt", self.work / "invalid.json"
                source.write_text(link + "\n")
                result = self.uc(str(LIB / "subscription/parser.uc"), "normalize-uri-list", str(source), str(output))
                if result.returncode == 0:
                    self.assertEqual(json.loads(output.read_text()).get("outbounds", []), [],
                                     "invalid ECH provider node was accepted without ECH")
                result, config = self.generate_result(links=[link])
                self.assertNotEqual(result.returncode, 0, "manual invalid ECH must produce an actionable error")
                self.assertIn("ECH", result.stdout + result.stderr)

    def cached_node(self, scheme="vless", tag="old-cache"):
        node = {"type": scheme, "tag": tag, "server": "node.example", "server_port": 443,
                "tls": {"enabled": True, "server_name": "target.example", "alpn": ["h2", "http/1.1"]}}
        if scheme in ["vless", "vmess"]:
            node["uuid"] = UUID
        else:
            node["password"] = "password"
        return node

    def test_legacy_cache_restores_uri_and_vmess_ech_without_rewriting_source(self):
        for scheme in ["vless", "vmess"]:
            for value in [B64, "ech.example+" + DOH]:
                with self.subTest(scheme=scheme, value=value[:20]):
                    node = self.cached_node(scheme)
                    node["share_link"] = self.link(value, scheme)
                    original = json.dumps({"outbounds": [node]})
                    config = self.generate(subscription=[node])
                    restored = next(o for o in config["outbounds"] if o["type"] == scheme)
                    if value == B64:
                        self.assert_static(restored)
                    else:
                        self.assertEqual(restored["tls"].get("ech"),
                                         {"enabled": True, "query_server_name": "ech.example"})
                        rule = config["dns"]["rules"][0]
                        resolver = next(s for s in config["dns"]["servers"] if s["tag"] == rule["server"])
                        self.assertEqual((rule.get("domain"), rule.get("query_type")), (["ech.example"], "HTTPS"))
                        self.assertEqual((resolver["type"], resolver["server"], resolver["path"]),
                                         ("https", "resolver.example", "/custom-dns"))
                        self.assertEqual(restored["tls"]["server_name"], "target.example")
                        self.assertEqual(restored["tls"]["alpn"], ["h2", "http/1.1"])
                    self.assertEqual((self.work / "subscriptions/proxy-subscription-1.json").read_text(), original,
                                     "upgrade must keep the offline source cache unchanged")

    def test_legacy_cache_skips_invalid_ech_but_keeps_other_offline_nodes(self):
        broken = self.cached_node(tag="broken-ech")
        broken["share_link"] = self.link("not base64!")
        working = self.cached_node(tag="working-offline")
        original = json.dumps({"outbounds": [broken, working]})
        config = self.generate(subscription=[broken, working])
        tags = {o["tag"] for o in config["outbounds"]}
        self.assertNotIn("broken-ech", tags)
        self.assertIn("working-offline", tags)
        self.assertEqual((self.work / "subscriptions/proxy-subscription-1.json").read_text(), original)

    def test_legacy_cache_preserves_explicit_ech_and_unextractable_non_ech_links(self):
        disabled = self.cached_node(tag="explicitly-disabled")
        disabled["tls"]["ech"] = {"enabled": False}
        disabled["share_link"] = self.link(B64)
        opaque = self.cached_node(tag="opaque-old-link")
        opaque["share_link"] = "vmess://not-a-valid-old-link"
        config = self.generate(subscription=[disabled, opaque])
        disabled_out = next(o for o in config["outbounds"] if o["tag"] == "explicitly-disabled")
        self.assertEqual(disabled_out["tls"]["ech"], {"enabled": False})
        self.assertTrue(any(o["tag"] == "opaque-old-link" for o in config["outbounds"]))

    def test_legacy_vmess_restoration_is_bounded_before_decoding_large_source(self):
        oversized = self.cached_node("vmess", tag="oversized-legacy-vmess")
        # Put ECH after a large unrelated field: a prefix-only inspection must
        # not silently miss ECH and leave this normalized node unprotected.
        source = {"add": "node.example", "port": "443", "id": UUID, "tls": "tls",
                  "padding": "x" * 200000, "ech": B64}
        oversized["share_link"] = "vmess://" + base64.b64encode(json.dumps(source).encode()).decode()
        self.assertGreater(len(oversized["share_link"]), 256 * 1024)
        working = self.cached_node(tag="working-bounded-cache")
        original = json.dumps({"outbounds": [oversized, working]})
        result, config = self.generate_result(subscription=[oversized, working])
        self.assertEqual(result.returncode, 0, result.stderr)
        tags = {o["tag"] for o in config["outbounds"]}
        self.assertNotIn("oversized-legacy-vmess", tags)
        self.assertIn("working-bounded-cache", tags)
        self.assertIn("ECH cache restoration size exceeds limit", result.stdout + result.stderr)
        self.assertEqual((self.work / "subscriptions/proxy-subscription-1.json").read_text(), original)

    def test_ech_with_tls_disabled_is_rejected(self):
        link = self.link(B64, security="none")
        result = self.uc(str(LIB / "subscription/parser.uc"), "share-link-outbound", link, "node")
        self.assertNotEqual(result.returncode, 0, "ECH cannot silently turn into plaintext")
        result, _ = self.generate_result(links=[link])
        self.assertNotEqual(result.returncode, 0)

    def test_conflicting_explicit_resolvers_are_rejected(self):
        result, _ = self.generate_result(links=[self.link("ech.example+" + DOH),
                      self.link("ech.example+https://other-resolver.example/dns-query")])
        self.assertNotEqual(result.returncode, 0, "global core DNS cannot honor two ECH resolvers for one name")
        self.assertIn("ECH", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
