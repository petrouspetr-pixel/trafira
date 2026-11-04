"""Loopback-only reproductions using the pinned real core in network CI."""
import copy
import http.server
import ipaddress
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class NetworkRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-fork-network-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = {**os.environ, "TRAFIRA_LIB": str(LIB)}

    def start_core(self, config):
        source = self.work / "core.json"
        source.write_text(json.dumps(config))
        log = (self.work / "core.log").open("w+")
        proc = subprocess.Popen(["sing-box", "run", "-c", str(source)], stdout=log, stderr=log)
        def stop():
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            log.close()
        self.addCleanup(stop)
        time.sleep(0.3)
        log.flush()
        self.assertIsNone(proc.poll(), (self.work / "core.log").read_text())
        return proc

    def generate(self, node, dns_port, settings=None):
        fixture = {"settings": {"dns_server": [f"127.0.0.1:{dns_port}"],
                                "bootstrap_dns_server": [f"127.0.0.1:{dns_port}"], **(settings or {})},
                   "section": [{".name": "proxy", "action": "connection",
                                "outbound_jsons": [json.dumps(node)]}]}
        source, output = self.work / "input.json", self.work / "generated.json"
        source.write_text(json.dumps(fixture))
        r = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "singbox/generator.uc"),
                            "generate-config-fixture", str(source), str(output), "127.0.0.1",
                            "0", "1", "", "1.14.2", "check-only"],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(output.read_text())

    @unittest.skipUnless(os.environ.get("EXTENDED_BIN"), "Pinned Extended check runs separately")
    def test_extended_base62_validation_matches_core(self):
        for length, accepted in [("4", False), ("5", False), ("4-5", False),
                                 ("4-8", True), ("6", True), ("6-8", True)]:
            with self.subTest(length=length):
                node = {"type": "vless", "server": "127.0.0.1", "server_port": 443,
                        "uuid": "00000000-0000-4000-8000-000000000001",
                        "transport": {"type": "xhttp", "path": "/", "mode": "auto",
                                      "x_padding_bytes": "100-1000", "no_grpc_header": False,
                                      "sc_max_each_post_bytes": 1000000, "sc_min_posts_interval_ms": 30,
                                      "session_id_table": "Base62", "session_id_length": length}}
                source = self.work / "extended.json"
                source.write_text(json.dumps({"outbounds": [node]}))
                result = subprocess.run([os.environ["EXTENDED_BIN"], "check", "-c", str(source)],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if not accepted:
                    self.assertIn("too small", result.stderr)

    def test_ech_query_reaches_dns_instead_of_being_refused(self):
        self.check_ech_query(False)

    def test_router_origin_ech_query_uses_bootstrap_before_router_dns(self):
        self.check_ech_query(True)

    def check_ech_query(self, router):
        queries = []
        class DNS(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                end = 12
                while data[end]:
                    end += data[end] + 1
                end += 5
                queries.append(struct.unpack("!H", data[end-4:end-2])[0])
                sock.sendto(data[:2] + struct.pack("!HHHHH", 0x8180, 1, 0, 0, 0) + data[12:end], self.client_address)
        dns = socketserver.UDPServer(("127.0.0.1", 0), DNS)
        self.addCleanup(dns.server_close)
        threading.Thread(target=dns.serve_forever, daemon=True).start()
        self.addCleanup(dns.shutdown)
        class Sink(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                try:
                    self.request.recv(4096)
                except TimeoutError:
                    pass
        sink = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Sink)
        sink.daemon_threads = True
        self.addCleanup(sink.server_close)
        threading.Thread(target=sink.serve_forever, daemon=True).start()
        self.addCleanup(sink.shutdown)
        node = {"type": "http", "server": "127.0.0.1", "server_port": sink.server_address[1],
                "tls": {"enabled": True, "server_name": "target.example",
                        "ech": {"enabled": True, "query_server_name": "ech.example"}}}
        config = self.generate(node, dns.server_address[1],
                               {"router_origin_enabled": "1", "router_origin_section": "proxy"} if router else {})
        if router:
            # No listener on port 9: an inherited router DNS catch-all must not
            # redirect ECH there instead of the working bootstrap. This also
            # detects the dependency that becomes a cycle with a TLS DNS detour.
            next(s for s in config["dns"]["servers"] if s["tag"] == "dns-server")["server_port"] = 9
        inbound_port, dns_inbound = port(), port()
        config["inbounds"] = [{"type": "mixed", "tag": "router-tproxy-in" if router else "test", "listen": "127.0.0.1", "listen_port": inbound_port},
                              {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": dns_inbound}]
        config["experimental"] = {}
        config["route"]["final"] = "proxy-out"
        config["log"] = {"level": "debug"}
        self.start_core(config)
        subprocess.run(["curl", "--max-time", "3", "-s", "--proxy", f"http://127.0.0.1:{inbound_port}",
                        "https://example.com/"], capture_output=True, timeout=5)
        self.assertIn(65, queries, "a real TLS ECH handshake must query HTTPS records upstream; " +
                      (self.work / "core.log").read_text())
        self.assertNotIn("REFUSED", (self.work / "core.log").read_text())
        # The exception must not turn off the normal HTTPS-record restriction.
        question = b"\x05other\x07example\x00" + struct.pack("!HH", 65, 1)
        packet = struct.pack("!HHHHHH", 123, 0x0100, 1, 0, 0, 0) + question
        count = len(queries)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2)
            sock.sendto(packet, ("127.0.0.1", dns_inbound))
            response, _ = sock.recvfrom(4096)
        self.assertEqual(response[3] & 15, 5, "unrelated HTTPS queries remain REFUSED")
        self.assertEqual(len(queries), count, "unrelated HTTPS query never reaches upstream")

    def test_fakeip_range_change_resets_only_fakeip_and_preserves_selector(self):
        dns_port, api_port = port(), port()
        generated = self.generate({"type": "direct"}, port())
        new_range = next(s["inet6_range"] for s in generated["dns"]["servers"] if s["type"] == "fakeip")
        config = {"log": {"disabled": True}, "inbounds": [{"type": "direct", "tag": "dns",
                  "listen": "127.0.0.1", "listen_port": dns_port}],
                  "dns": {"servers": [{"type": "fakeip", "tag": "fake", "inet4_range": "198.18.0.0/15",
                                        "inet6_range": "fc00::/18"},
                                       {"type": "udp", "tag": "real", "server": "127.0.0.1", "server_port": 9}],
                          "rules": [{"query_type": "AAAA", "action": "route", "server": "fake"}], "final": "real"},
                  "route": {"default_domain_resolver": "real",
                            "rules": [{"action": "sniff"}, {"action": "hijack-dns", "protocol": "dns"}]},
                  "outbounds": [{"type": "direct", "tag": "A"}, {"type": "direct", "tag": "B"},
                                {"type": "selector", "tag": "choice", "outbounds": ["A", "B"]}],
                  "experimental": {"cache_file": {"enabled": True, "store_fakeip": True,
                                                   "path": str(self.work / "cache.db")},
                                   "clash_api": {"external_controller": f"127.0.0.1:{api_port}"}}}
        def address():
            r = subprocess.run(["dig", "@127.0.0.1", "-p", str(dns_port), "host.example", "AAAA",
                                "+short", "+timeout=2", "+tries=1"], capture_output=True, text=True, timeout=4)
            self.assertEqual(r.returncode, 0, r.stderr)
            return ipaddress.ip_address(r.stdout.strip())
        first = self.start_core(config)
        self.assertIn(address(), ipaddress.ip_network("fc00::/18"))
        req = urllib.request.Request(f"http://127.0.0.1:{api_port}/proxies/choice", method="PUT",
                                     data=b'{"name":"B"}', headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=2) as response:
            self.assertEqual(response.status, 204)
        first.terminate()
        first.wait(timeout=5)
        config["dns"]["servers"][0]["inet6_range"] = new_range
        self.start_core(config)
        self.assertIn(address(), ipaddress.ip_network("2001:2::/112"))
        with urllib.request.urlopen(f"http://127.0.0.1:{api_port}/proxies/choice", timeout=2) as response:
            self.assertEqual(json.load(response)["now"], "B", "no deletion of unrelated selector state")

    def test_imported_ech_uses_its_explicit_https_dns_and_bootstrap(self):
        queries, requests = [], []
        class Bootstrap(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                end, labels = 12, []
                while data[end]:
                    size = data[end]
                    labels.append(data[end+1:end+1+size].decode())
                    end += size + 1
                end += 5
                kind = struct.unpack("!H", data[end-4:end-2])[0]
                queries.append((".".join(labels), kind))
                answer = b""
                if kind == 1:
                    answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.1")
                sock.sendto(data[:2] + struct.pack("!HHHHH", 0x8180, 1, bool(answer), 0, 0) +
                            data[12:end] + answer, self.client_address)
        dns = socketserver.UDPServer(("127.0.0.1", 0), Bootstrap)
        self.addCleanup(dns.server_close)
        threading.Thread(target=dns.serve_forever, daemon=True).start()
        self.addCleanup(dns.shutdown)
        cert, key = self.work / "cert.pem", self.work / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cert), "-days", "1",
                        "-subj", "/CN=resolver.example", "-addext", "subjectAltName=DNS:resolver.example",
                        "-addext", "basicConstraints=critical,CA:TRUE"],
                       capture_output=True, check=True, timeout=15)
        class DoH(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(self.path)
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                end = 12
                while data[end]:
                    end += data[end] + 1
                end += 5
                response = data[:2] + struct.pack("!HHHHH", 0x8180, 1, 0, 0, 0) + data[12:end]
                self.send_response(200)
                self.send_header("Content-Type", "application/dns-message")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            def log_message(self, *_):
                pass
        doh = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DoH)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        tls.set_alpn_protocols(["http/1.1"])
        doh.socket = tls.wrap_socket(doh.socket, server_side=True)
        self.addCleanup(doh.server_close)
        threading.Thread(target=doh.serve_forever, daemon=True).start()
        self.addCleanup(doh.shutdown)
        class Sink(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                try:
                    self.request.recv(4096)
                except TimeoutError:
                    pass
        sink = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Sink)
        sink.daemon_threads = True
        self.addCleanup(sink.server_close)
        threading.Thread(target=sink.serve_forever, daemon=True).start()
        self.addCleanup(sink.shutdown)
        ech = urllib.parse.quote(f"ech.example+https://resolver.example:{doh.server_port}/ech-record", safe="")
        link = ("vless://00000000-0000-4000-8000-000000000001@127.0.0.1:" +
                str(sink.server_address[1]) + "?security=tls&sni=target.example&ech=" + ech)
        fixture = {"settings": {"dns_server": ["127.0.0.1:9"],
                                "bootstrap_dns_server": [f"127.0.0.1:{dns.server_address[1]}"]},
                   "section": [{".name": "proxy", "action": "connection", "selector_proxy_links": [link]}]}
        source, output = self.work / "input.json", self.work / "generated.json"
        source.write_text(json.dumps(fixture))
        generated = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "singbox/generator.uc"),
                                    "generate-config-fixture", str(source), str(output), "127.0.0.1",
                                    "0", "1", "", "1.14.2", "check-only"],
                                   env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        config = json.loads(output.read_text())
        inbound = port()
        config["inbounds"] = [{"type": "mixed", "tag": "test", "listen": "127.0.0.1", "listen_port": inbound}]
        config["route"]["final"] = "proxy-out"
        config["certificate"] = {"certificate_path": [str(cert)]}
        config["experimental"] = {}
        config["log"] = {"level": "debug"}
        self.start_core(config)
        subprocess.run(["curl", "--max-time", "3", "-s", "--proxy", f"http://127.0.0.1:{inbound}",
                        "https://example.com/"], capture_output=True, timeout=5)
        log = (self.work / "core.log").read_text()
        self.assertEqual(requests, ["/ech-record"], log)
        self.assertTrue(any(name == "resolver.example" and kind == 1 for name, kind in queries), log)

    def test_stalled_local_api_returns_a_bounded_structured_error(self):
        self.check_stalled_api("get_connections", [])

    def test_bulk_metadata_timeout_stops_before_measuring_any_nodes(self):
        self.check_stalled_api("get_proxy_latencies", ['["group","node"]', "5000"])

    def test_probe_has_http_deadline_independent_of_core_timeout(self):
        self.check_stalled_api("get_proxy_latency", ["node", "100"])

    def check_stalled_api(self, action, arguments):
        release = threading.Event()
        paths = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                paths.append(self.path)
                release.wait(8)
            def log_message(self, *_):
                pass
        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        api.daemon_threads = True
        self.addCleanup(api.server_close)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        self.addCleanup(api.shutdown)
        self.addCleanup(release.set)
        state = self.work / "uci"
        state.write_text("trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n")
        env = {**self.env, "TRAFIRA_UCI_STATE_FILE": str(state),
               "SB_CLASH_API_CONTROLLER_PORT": str(api.server_address[1])}
        started = time.monotonic()
        result = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "diagnostics/runtime.uc"),
                                 "clash-api", action, *arguments], env=env, capture_output=True, text=True, timeout=7)
        self.assertLess(time.monotonic() - started, 7)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error", json.loads(result.stdout))
        if action == "get_proxy_latency":
            self.assertEqual(len(paths), 1)
            self.assertTrue(paths[0].startswith("/proxies/node/delay?"))
        else:
            self.assertEqual(paths, ["/connections" if action == "get_connections" else "/proxies"])

    def test_large_api_reply_without_content_length_is_bounded(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()  # Deliberately no Content-Length.
                try:
                    self.wfile.write(b'{"connections":[],"padding":"')
                    for _ in range(768):
                        self.wfile.write(b'x' * 4096)
                    self.wfile.write(b'"}')
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_):
                pass
        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        api.daemon_threads = True
        self.addCleanup(api.server_close)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        self.addCleanup(api.shutdown)
        state = self.work / "uci"
        state.write_text("trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n")
        env = {**self.env, "TRAFIRA_UCI_STATE_FILE": str(state),
               "SB_CLASH_API_CONTROLLER_PORT": str(api.server_address[1])}
        result = subprocess.run(["ucode", "-L", str(LIB), str(LIB / "diagnostics/runtime.uc"),
                                 "clash-api", "get_connections"], env=env, capture_output=True, text=True, timeout=7)
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(len(result.stdout), 1024)
        self.assertIn("too_large", json.loads(result.stdout)["error"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
