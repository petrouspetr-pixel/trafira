"""Loopback-only HTTP and SOCKS fixtures inside the CI network namespace."""
import http.server
import select
import socket
import socketserver
import struct
import sys
import threading


def receive(stream, size):
    result = b""
    while len(result) < size:
        chunk = stream.recv(size - len(result))
        if not chunk:
            raise OSError("peer closed")
        result += chunk
    return result


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(5)
        try:
            version, count = receive(client, 2)
            if version != 5:
                return
            receive(client, count)
            client.sendall(b"\x05\x00")
            version, command, _, kind = receive(client, 4)
            if version != 5 or command != 1:
                return
            if kind == 1:
                address = socket.inet_ntop(socket.AF_INET, receive(client, 4))
            elif kind == 4:
                address = socket.inet_ntop(socket.AF_INET6, receive(client, 16))
            elif kind == 3:
                address = receive(client, receive(client, 1)[0]).decode("ascii")
            else:
                return
            port = struct.unpack("!H", receive(client, 2))[0]
            # The fixture cannot become a proxy to the runner or public network.
            if address not in ("198.51.100.2", "2001:db8:1::2") or port != 18080:
                return
            with socket.create_connection((address, port), timeout=5) as remote:
                client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                while True:
                    ready, _, _ = select.select([client, remote], [], [], 5)
                    if not ready:
                        return
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        (remote if source is client else client).sendall(data)
        except (OSError, ValueError):
            return


class Http(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"protected network test\n")

    def log_message(self, *_):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Server6(Server):
    address_family = socket.AF_INET6


if sys.argv[1] == "http":
    first = Server(("198.51.100.2", 18080), Http)
    second = Server6(("2001:db8:1::2", 18080), Http)
    threading.Thread(target=second.serve_forever, daemon=True).start()
    first.serve_forever()
else:
    Server(("198.51.100.2", int(sys.argv[1])), Socks).serve_forever()
