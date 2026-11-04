#!/usr/bin/env python3
"""Verify the generated selector policy with real TCP streams on loopback only."""
import json
import os
import pathlib
import re
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

if os.environ.get("RUN_TRAFIRA_NETWORK_TESTS") != "1":
    raise SystemExit("SKIP: isolated network tests are disabled")

LIB = str(pathlib.Path(__file__).resolve().parents[2] / "trafira/files/usr/lib")


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while data := self.request.recv(1024):
                self.request.sendall(self.client_address[0].encode() + b":" + data)
        except OSError:
            pass


def exact(stream, length):
    data = b""
    while len(data) < length:
        chunk = stream.recv(length - len(data))
        if not chunk:
            raise ConnectionError("TCP stream was closed")
        data += chunk
    return data


def free_port():
    with socket.socket() as stream:
        stream.bind(("127.0.0.1", 0))
        return stream.getsockname()[1]


def client(port, destination):
    stream = socket.create_connection(("127.0.0.1", port), timeout=2)
    try:
        stream.sendall(b"\x05\x01\x00")
        assert exact(stream, 2) == b"\x05\x00", "SOCKS authentication failed"
        stream.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", destination))
        assert exact(stream, 4) == b"\x05\x00\x00\x01", "SOCKS connection failed"
        exact(stream, 6)
        return stream
    except BaseException:
        stream.close()
        raise


def exchange(stream, address):
    stream.sendall(b"ping")
    assert exact(stream, len(address) + 5) == address.encode() + b":ping", "wrong outbound used"


version = subprocess.check_output(["sing-box", "version"], text=True).splitlines()[0]
match = re.search(r"\b(\d+)\.(\d+)\.", version)
assert match, "could not identify sing-box version"
# Before 1.14 Selector.NewConnectionEx delegates directly to the selected
# outbound, bypassing the selector interrupt group for inbound client streams.
# Preserve the old engine behavior; test the close control where it is wired.
tracks_client_streams = tuple(map(int, match.groups())) >= (1, 14)
values = [None, "0", "1"] if tracks_client_streams else ["0"]
if not tracks_client_streams:
    print("NOTE: sing-box before 1.14 bypasses the selector interrupt group for client streams; testing preserve mode only", flush=True)

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo) as echo, tempfile.TemporaryDirectory(prefix="trafira-selector-network-") as temp:
    echo.daemon_threads = True
    thread = threading.Thread(target=echo.serve_forever, daemon=True)
    thread.start()
    try:
        for value in values:
            directory = pathlib.Path(temp) / str(value)
            directory.mkdir()
            section = {".name": "demo", ".type": "section", "enabled": "1", "action": "connection", "outbound_jsons": [
                json.dumps({"type": "direct", "tag": "A", "inet4_bind_address": "127.0.0.2"}),
                json.dumps({"type": "direct", "tag": "B", "inet4_bind_address": "127.0.0.3"})]}
            if value is not None:
                section["selector_interrupt_exist_connections"] = value
            fixture, generated = directory / "fixture.json", directory / "generated.json"
            fixture.write_text(json.dumps({"settings": {".name": "settings", ".type": "settings"}, "section": [section]}))
            pathlib.Path(str(generated) + ".section-cache").mkdir()
            subprocess.run(["ucode", "-L", LIB, LIB + "/singbox/generator.uc", "generate-config-fixture", str(fixture), str(generated), "127.0.0.1"], check=True)
            outbounds = [outbound for outbound in json.loads(generated.read_text())["outbounds"] if outbound["tag"] in ["A", "B", "demo-out"]]
            assert len(outbounds) == 3, "generated selector or members missing"
            mixed, api = free_port(), free_port()
            while api == mixed:
                api = free_port()
            config = directory / "config.json"
            config.write_text(json.dumps({"log": {"disabled": True}, "inbounds": [{"type": "mixed", "tag": "client", "listen": "127.0.0.1", "listen_port": mixed}],
                "outbounds": outbounds, "route": {"final": "demo-out"},
                "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{api}"}}}))
            subprocess.run(["sing-box", "check", "-c", str(config)], check=True)
            with (directory / "core.log").open("wb") as log:
                process = subprocess.Popen(["sing-box", "run", "-c", str(config)], stdout=log, stderr=log)
                try:
                    endpoint = f"http://127.0.0.1:{api}/proxies/demo-out"
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            with opener.open(endpoint, timeout=1) as response:
                                assert json.load(response)["now"] == "A"
                            break
                        except (OSError, urllib.error.URLError):
                            if process.poll() is not None or time.monotonic() >= deadline:
                                raise AssertionError("sing-box did not start")
                            time.sleep(0.05)
                    with client(mixed, echo.server_address[1]) as old:
                        exchange(old, "127.0.0.2")
                        request = urllib.request.Request(endpoint, data=b'{"name":"B"}', headers={"Content-Type": "application/json"}, method="PUT")
                        with opener.open(request, timeout=2) as response:
                            assert response.status == 204
                        with client(mixed, echo.server_address[1]) as new:
                            exchange(new, "127.0.0.3")
                        if value == "0":
                            exchange(old, "127.0.0.2")
                        else:
                            deadline = time.monotonic() + 2
                            while True:
                                try:
                                    exchange(old, "127.0.0.2")
                                except ConnectionError:
                                    break
                                assert time.monotonic() < deadline, "old stream survived with interrupt enabled"
                                time.sleep(0.02)
                    print(f"PASS selector={value}: new TCP via B; old TCP " + ("preserved via A" if value == "0" else "closed"), flush=True)
                except BaseException:
                    print((directory / "core.log").read_text(errors="replace"), flush=True)
                    raise
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    finally:
        echo.shutdown()
        thread.join(timeout=2)
