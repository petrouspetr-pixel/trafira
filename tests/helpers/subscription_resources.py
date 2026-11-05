"""Bounded subscription I/O using real ucode and loopback HTTP; no host UCI."""
import base64
import gzip
import http.server
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"
SOURCE_LIMIT = 8 * 1024 * 1024
CACHE_LIMIT = 32 * 1024 * 1024
NODE = {"type": "socks", "tag": "working", "server": "127.0.0.1", "server_port": 1080}
VALID = json.dumps({"outbounds": [NODE]}).encode()


class SubscriptionResources(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-subscription-resources-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = dict(os.environ, TRAFIRA_LIB=str(LIB),
                        TMP_SING_BOX_FOLDER=str(self.work / "sing-box"),
                        TMP_SUBSCRIPTION_FOLDER=str(self.work / "subscriptions"),
                        TRAFIRA_RUNTIME_STATE_DIR=str(self.work / "run"),
                        TRAFIRA_SECTION_CACHE_DIR=str(self.work / "sections"),
                        TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR=str(self.work / "persistent"),
                        TRAFIRA_UCI_STATE_FILE=str(self.work / "uci"),
                        TRAFIRA_SUBSCRIPTION_DOWNLOAD_BUDGET="2")

    def uc(self, *args, timeout=12, memory=None, file_size=None):
        def bound():
            if memory:
                resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
            if file_size:
                signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                resource.setrlimit(resource.RLIMIT_FSIZE, (file_size, file_size))
        command = ["ucode", "-L", str(LIB), *args]
        process = subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True,
                                   preexec_fn=bound if memory or file_size else None)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The old downloader can leave curl holding our capture pipes.
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def serve(self, behavior, payload=VALID):
        owner = self
        self.paths = []
        self.release = threading.Event()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.paths.append(self.path)
                self.send_response(200)
                if behavior == "declared-large":
                    self.send_header("Content-Length", str(len(VALID[:-1]) + 12 + SOURCE_LIMIT + 1 + 2))
                elif behavior == "valid":
                    self.send_header("Content-Length", str(len(payload)))
                self.send_header("profile-title", "Guard fixture")
                self.end_headers()
                try:
                    if behavior == "slow":
                        while not owner.release.wait(0.05):
                            self.wfile.write(b"x")
                            self.wfile.flush()
                    elif behavior in ("large", "declared-large"):
                        self.wfile.write(VALID[:-1] + b',"padding":"')
                        for _ in range(SOURCE_LIMIT // 65536):
                            self.wfile.write(b"x" * 65536)
                        self.wfile.write(b'x"}')
                    else:
                        self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(self.release.set)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{server.server_port}/private-token-not-for-logs"
        (self.work / "uci").write_text(
            "trafira.settings=settings\ntrafira.proxy=section\n"
            "trafira.proxy.connection_type=proxy\ntrafira.proxy.action=connection\n"
            "trafira.source=subscription_url\ntrafira.source.section=proxy\n"
            f"trafira.source.url={self.url}\ntrafira.source.auto_user_agent=0\n"
            "trafira.source.user_agent=GuardTest\n")
        return self.url

    def seed_cache(self):
        folder = self.work / "subscriptions"
        folder.mkdir(exist_ok=True)
        self.cached = folder / "proxy-subscription-1.json"
        self.cached.write_bytes(VALID)
        (folder / "proxy-subscription-1.url").write_text(self.url)
        (folder / "proxy-subscription-1.user_agent").write_text("GuardTest")
        (folder / "proxy-subscription-1.hwid").write_text("")
        (folder / "proxy-subscription-1.device_headers").write_text("")

    def update(self, timeout=12):
        return self.uc(str(LIB / "subscription/cache.uc"), "update-source", "proxy", "1",
                       self.url, "runtime", "", timeout=timeout)

    def test_trickling_response_obeys_source_budget_and_preserves_cache(self):
        self.serve("slow")
        self.seed_cache()
        started = time.monotonic()
        try:
            result = self.update(timeout=5)
        except subprocess.TimeoutExpired:
            self.fail("trickling subscription exceeded total download budget")
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cached.read_bytes(), VALID)
        self.assertNotIn("private-token-not-for-logs", result.stdout + result.stderr)
        self.assertFalse(list((self.work / "subscriptions").glob("*.part.*")))

    def test_oversized_download_is_rejected_before_cache_replacement(self):
        for behavior in ["large", "declared-large"]:
            with self.subTest(behavior=behavior):
                self.serve(behavior)
                self.seed_cache()
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.cached.read_bytes(), VALID)
                self.assertEqual(len(self.paths), 1, "oversize must not retry compatibility profiles")
                self.assertFalse(list((self.work / "subscriptions").glob("*.part.*")))

    def test_supported_formats_update_normally(self):
        uri = b"socks5://127.0.0.1:1080#working\n"
        yaml = b"proxies:\n  - name: working\n    type: socks5\n    server: 127.0.0.1\n    port: 1080\n"
        for payload in [VALID, uri, base64.b64encode(uri), gzip.compress(uri), yaml]:
            with self.subTest(payload=payload[:25]):
                self.serve("valid", payload)
                result = self.update()
                self.assertIn(result.returncode, (0, 2), result.stdout + result.stderr)
                cache = self.work / "subscriptions/proxy-subscription-1.json"
                self.assertTrue(json.loads(cache.read_text())["outbounds"])

    def test_parser_rejects_oversize_plain_and_gzip_expansion(self):
        for compressed in [False, True]:
            with self.subTest(compressed=compressed):
                # Valid JSON with a large unrelated field must still be bounded.
                source = VALID[:-1] + b',"padding":"' + b"x" * SOURCE_LIMIT + b'"}'
                path, output = self.work / "input", self.work / "output.json"
                path.write_bytes(gzip.compress(source) if compressed else source)
                output.unlink(missing_ok=True)
                result = self.uc(str(LIB / "subscription/parser.uc"),
                                 "normalize-content-validated", str(path), str(output))
                self.assertNotEqual(result.returncode, 0, "oversized input was materialized and accepted")
                self.assertFalse(output.exists(), "rejected parse left successful-looking output")

    def test_gzip_header_detection_uses_binary_bytes(self):
        path = self.work / "binary-gzip"
        path.write_bytes(gzip.compress(VALID))
        result = self.uc("-e", 'exit(require("subscription.parser").content_is_gzip(ARGV[0])?0:1);', str(path))
        self.assertEqual(result.returncode, 0, "gzip magic was not recognized: " + result.stderr)

    def test_cache_io_binary_identity_and_bounded_memory(self):
        source, target = self.work / "binary", self.work / "copy"
        block = bytes(range(256)) * 256
        with source.open("wb") as output:
            for _ in range(CACHE_LIMIT // len(block)):
                output.write(block)
        script = ('let io=require("subscription.io");'
                  'if(!io.copy_file(ARGV[0],ARGV[1])||!io.files_equal(ARGV[0],ARGV[1]))exit(1);')
        result = self.uc("-e", script, str(source), str(target), memory=48 * 1024 * 1024)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.stat().st_size, CACHE_LIMIT)
        with target.open("r+b") as output:
            output.seek(CACHE_LIMIT // 2)
            output.write(b"different")
        result = self.uc("-e", 'exit(require("subscription.io").files_equal(ARGV[0],ARGV[1])?1:0);',
                         str(source), str(target), memory=48 * 1024 * 1024)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bounded_reads_and_failed_copy_do_not_damage_target(self):
        source, target = self.work / "source", self.work / "target"
        source.write_bytes(b"abcd")
        target.write_bytes(b"retained")
        script = ('let io=require("subscription.io"),fs=require("fs");'
                  'if(io.read_file(ARGV[0],3)!=null||io.read_file(ARGV[0],4)!="abcd")exit(1);'
                  'if(io.copy_file(ARGV[0]+".missing",ARGV[1]))exit(2);'
                  'if(fs.readfile(ARGV[1])!="retained")exit(3);')
        result = self.uc("-e", script, str(source), str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.uc("-e", 'exit(require("subscription.io").read_file(ARGV[0],33554432)=="abcd"?0:1);',
                         str(source), memory=24 * 1024 * 1024)
        self.assertEqual(result.returncode, 0, "small reads must not allocate the entire size ceiling: " + result.stderr)

    def test_buffered_write_failure_keeps_last_complete_copy(self):
        source, target = self.work / "short-source", self.work / "last-complete"
        source.write_bytes(b"x" * 512)
        target.write_bytes(b"retained")
        result = self.uc("-e", 'exit(require("subscription.io").copy_file(ARGV[0],ARGV[1])?1:0);',
                         str(source), str(target), file_size=256)
        self.assertEqual(result.returncode, 0, "buffered flush failure was reported as a complete copy: " + result.stderr)
        self.assertEqual(target.read_bytes(), b"retained")
        self.assertFalse(list(self.work.glob("last-complete.*.tmp")))

    def test_gzip_and_link_population_keep_input_after_buffered_write_failure(self):
        source = self.work / "compressed"
        compressed = gzip.compress(VALID[:-1] + b',"padding":"' + b"x" * 512 + b'"}')
        source.write_bytes(compressed)
        result = self.uc(str(LIB / "subscription/parser.uc"), "try-decode-gzip-content", str(source), file_size=256)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(source.read_bytes(), compressed)
        source = self.work / "normalized"
        original = json.dumps({"outbounds": [{**NODE, "tag": "n" * 300}]}).encode()
        source.write_bytes(original)
        result = self.uc("-e", 'exit(require("subscription.share_link").populate_subscription_file(ARGV[0])?1:0);',
                         str(source), file_size=256)
        self.assertEqual(result.returncode, 0, "truncated link-populated cache was accepted: " + result.stderr)
        self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
