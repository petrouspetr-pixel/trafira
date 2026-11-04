"""Exercise actual ucode with a streaming curl stand-in, including no size header."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "trafira/files/usr/lib"
LIMIT = 2 * 1024 * 1024


class MonitorTransport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trafira-monitor-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / "bin").mkdir()
        (self.work / "uci").write_text("trafira.settings=settings\ntrafira.settings.service_listen_address=127.0.0.1\n")
        curl = self.work / "bin/curl"
        curl.write_text('''#!/usr/bin/env python3
import sys,os,json
a=sys.argv[1:]
with open(os.environ["CURL_CALLS"],"a") as f:f.write(json.dumps(a)+"\\n")
url=next(v for v in a if ":9090/" in v)
mode=os.environ.get("CURL_MODE","")
if mode=="map-failure" and url.endswith("/proxies"):sys.exit(28)
if mode=="deadline":
 assert "--max-time" in a, "missing actual HTTP deadline"
 assert 0<float(a[a.index("--max-time")+1])<=65
if url.endswith("/connections"):
 size=int(os.environ.get("RESPONSE_BYTES","64"))
 prefix=b'{"connections":[],"padding":"'
 suffix=b'"}'
 sys.stdout.buffer.write(prefix)
 left=size-len(prefix)-len(suffix)
 while left>0:
  chunk=b'x'*min(left,4096);sys.stdout.buffer.write(chunk);left-=len(chunk)
 sys.stdout.buffer.write(suffix)
elif url.endswith("/proxies"):print('{"proxies":{"group":{"type":"URLTest"},"node":{"type":"VLESS"}}}')
elif "/group/" in url:print('{"node":12}')
else:print('{"delay":12}')
''')
        curl.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.work / "bin") + os.pathsep + os.environ["PATH"],
                    "TRAFIRA_LIB": str(LIB), "TRAFIRA_UCI_STATE_FILE": str(self.work / "uci"),
                    "TRAFIRA_RUNTIME_STATE_DIR": str(self.work / "runtime"),
                    "CURL_CALLS": str(self.work / "calls")}

    def call(self, action, *args):
        return subprocess.run(["ucode", "-L", str(LIB), str(LIB / "diagnostics/runtime.uc"),
                               "clash-api", action, *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_bulk_types_and_every_probe_have_a_transport_deadline(self):
        self.env["CURL_MODE"] = "deadline"
        result = self.call("get_proxy_latencies", '["group","node"]', "5000")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        calls = [json.loads(v) for v in (self.work / "calls").read_text().splitlines()]
        self.assertEqual(len(calls), 3)
        self.assertTrue(any("/group/group/delay" in str(v) for v in calls), "group identity must be retained")
        self.assertTrue(all("--max-time" in v for v in calls))

    def test_failed_type_snapshot_aborts_before_false_measurements(self):
        self.env["CURL_MODE"] = "map-failure"
        result = self.call("get_proxy_latencies", '["group","node"]', "5000")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error", json.loads(result.stdout))
        self.assertNotIn("/delay", (self.work / "calls").read_text())

    def test_streaming_oversize_is_not_parsed_or_returned_as_success(self):
        self.env["RESPONSE_BYTES"] = str(LIMIT + 1)
        result = self.call("get_connections")
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(len(result.stdout), 1024, "no oversized body is returned to RPC")
        self.assertIn("too_large", json.loads(result.stdout)["error"])

    def test_response_exactly_at_limit_and_small_response_still_work(self):
        for size in [64, LIMIT]:
            with self.subTest(size=size):
                self.env["RESPONSE_BYTES"] = str(size)
                result = self.call("get_connections")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["connections"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
