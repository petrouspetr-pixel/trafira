"""HTTP, verified TLS and DNS fixtures confined to the WARP test namespace."""
import http.server
import socket
import socketserver
import ssl
import struct
import sys
import threading
class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.end_headers();self.wfile.write(b"warp=on\n")
    def log_message(self,*args): pass
class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
class TCP6(TCP): address_family=socket.AF_INET6
class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        query,sock=self.request
        if len(query)<12:return
        pos=12
        while pos<len(query) and query[pos]:pos+=query[pos]+1
        end=pos+5
        if end>len(query):return
        kind=struct.unpack('!H',query[pos+1:pos+3])[0]
        answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,1,4)+socket.inet_aton('198.51.100.2') if kind==1 else b''
        response=query[:2]+struct.pack('!HHHHH',0x8180,1,bool(answer),0,0)+query[12:end]+answer
        sock.sendto(response,self.client_address)
servers=[]
for cls,address,port in [(TCP,'198.51.100.2',18080),(TCP6,'2001:db8:1::2',18080),(TCP,'198.51.100.2',18443),(TCP,'1.1.1.1',443)]:
    srv=cls((address,port),HTTP)
    if port!=18080:
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(sys.argv[1],sys.argv[2]);srv.socket=ctx.wrap_socket(srv.socket,server_side=True)
    servers.append(srv)
servers.append(socketserver.ThreadingUDPServer(('198.51.100.2',53),DNS))
for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
threading.Event().wait()
