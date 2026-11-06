#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
"""Exercise the production list downloader against local HTTP framing variants."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

root = Path(sys.argv[1])
library = root / "trafira/files/usr/lib"
source = (library / "components/updates.uc").read_text()
matched = re.search(r"^function download_to_file\([^\n]*\) \{\n.*?^\}", source, re.M | re.S)
assert matched, "production download_to_file missing"
# Generic text/JSON lists can exceed a compiled snapshot's 4 MiB allowance.
# Keep an explicit 8 MiB contract; do not infer the expected cap from production.
limit = 8 * 1024 * 1024
oversized = 2 * limit
block = b"example.org\n" * 1024
requests = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        case, framing, count = self.path.strip("/").split("/")
        count = int(count)
        record = {"case": case, "sent": 0, "done": False}
        requests.append(record)
        self.send_response(200)
        if framing == "length":
            self.send_header("Content-Length", str(count))
        elif framing == "chunked":
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        try:
            while record["sent"] < count:
                data = block[:min(len(block), count - record["sent"])]
                if framing == "chunked":
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                else:
                    self.wfile.write(data)
                record["sent"] += len(data)
                # Give the disk sampler time to observe oversized writes. This
                # also makes early abort observable without external network.
                if case.startswith("oversize"):
                    time.sleep(0.001)
            if framing == "chunked":
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            record["done"] = True


with tempfile.TemporaryDirectory(prefix="trafira-list-size-") as temporary:
    work = Path(temporary)
    binaries = work / "bin"
    binaries.mkdir()
    # Retain real curl; only skip retry pauses as in list_download_deadline.sh.
    (binaries / "sleep").write_text("#!/bin/sh\nexit 0\n")
    (binaries / "sleep").chmod(0o755)
    fixture = work / "download.uc"
    fixture.write_text(r'''
let fs = require("fs");
let as_string = v => v == null ? "" : "" + v;
let shell_quote = v => "'" + replace(as_string(v), /'/g, "'\\''") + "'";
let command_from_args = args => join(" ", map(args, shell_quote));
let command_success = command => system(command) == 0;
let command_success_from_args = args => command_success(command_from_args(args));
let log_message = (message, level) => null;
let remove_file = path => fs.unlink(path);
''' + matched.group(0) + '\nexit(download_to_file(ARGV[0], ARGV[1], "", "size-fixture") ? 0 : 1);\n')
    env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
               NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        cases = [("small", framing, 12345, True) for framing in ["length", "close", "chunked"]]
        cases += [("boundary", "chunked", limit, True)]
        cases += [("oversize-" + framing, framing, oversized, False) for framing in ["length", "close", "chunked"]]
        for case, framing, count, accepted in cases:
            destination = work / case
            destination.mkdir()
            output = destination / "list.tmp"
            url = f"http://127.0.0.1:{server.server_port}/{case}/{framing}/{count}"
            process = subprocess.Popen(["ucode", "-L", str(library), str(fixture), url, str(output)],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True)
            peak = 0
            deadline = time.monotonic() + 15
            try:
                while process.poll() is None:
                    sizes = []
                    for file in destination.rglob("*"):
                        with contextlib.suppress(FileNotFoundError):
                            if file.is_file():
                                sizes.append(file.stat().st_size)
                    peak = max(peak, sum(sizes))
                    if time.monotonic() >= deadline:
                        raise AssertionError(f"{case}: download exceeded local test deadline")
                    time.sleep(0.001)
                stdout, stderr = process.communicate(timeout=2)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=2)
            if accepted:
                assert process.returncode == 0, (case, stdout, stderr)
                expected = (block * (count // len(block) + 1))[:count]
                assert output.read_bytes() == expected, f"{case}: successful body was truncated or changed"
                assert list(destination.iterdir()) == [output], f"{case}: successful download leaked temporary files"
            else:
                assert process.returncode == 1, f"{case}: oversized response reported success: {stdout} {stderr}"
                assert not list(destination.iterdir()), f"{case}: partial download/staging was not removed"
                assert peak <= limit + 65536, f"{case}: temporary download exceeded cap: peak={peak}"
                case_requests = [record for record in requests if record["case"] == case]
                assert case_requests, f"{case}: no real HTTP request was made"
                until = time.monotonic() + 2
                while any(not record["done"] for record in case_requests) and time.monotonic() < until:
                    time.sleep(0.005)
                assert all(record["done"] and record["sent"] < count for record in case_requests), \
                    f"{case}: oversized bodies were downloaded completely: {case_requests}"
            print(f"PASS {case} framing={framing} bytes={count} accepted={accepted} peak={peak}")
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=2)
print("List download size checks passed")
PY
