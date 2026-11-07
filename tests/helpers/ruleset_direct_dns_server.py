"""Local TLS list server and independent DNS, inside a test network namespace."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import ssl
import struct
import sys
import threading

root = Path(sys.argv[1])
payload = b'{"version":3,"rules":[{"domain_suffix":["cold-bootstrap.example"]}]}'
dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
dns.bind(("127.0.0.2", 15353))


def serve_dns():
    while True:
        request, address = dns.recvfrom(4096)
        offset, labels = 12, []
        while request[offset]:
            size = request[offset]
            labels.append(request[offset + 1:offset + 1 + size].decode("ascii"))
            offset += size + 1
        offset += 1
        name = ".".join(labels).lower()
        kind = struct.unpack("!H", request[offset:offset + 2])[0]
        with (root / "dns.log").open("a") as output:
            output.write(name + "\n")
        found = name == "cold-list.invalid"
        answer = b""
        if found and kind == 1:
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("127.0.0.2")
        reply = request[:2] + struct.pack("!HHHHH", 0x8180 if found else 0x8183, 1, bool(answer), 0, 0)
        dns.sendto(reply + request[12:offset + 4] + answer, address)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with (root / "https.log").open("a") as output:
            output.write(self.path + "\n")
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer(("127.0.0.2", 18443), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(root / "cert.pem", root / "key.pem")
server.socket = tls.wrap_socket(server.socket, server_side=True)
threading.Thread(target=serve_dns, daemon=True).start()
(root / "ready").touch()
server.serve_forever()
