"""Exercise actual ucode resolve rules in a private sing-box with loopback traffic."""
import http.server
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'route-ip-resolve-ok')

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('0.0.0.0', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
target_port = server.server_port
lib = sys.argv[1]
request = {
    'section': {'.name': 'DE', 'action': 'connection', 'resolve_real_ip_for_routing': '1'},
    'rule': {'inbound': ['tproxy-in'], 'source_ip_cidr': ['127.0.0.1/32'],
             'port': [target_port], 'rule_set': ['domain-list', 'ip-list'],
             'action': 'route', 'outbound': 'DE-out'},
}
ucode = '''let fs=require("fs"),r=require("singbox.route"),v=json(fs.readfile(ARGV[0]));
print(sprintf("%J",r.resolve_rule_for_section(v.section,v.rule)));'''

try:
    with tempfile.TemporaryDirectory(prefix='trafira-ip-resolve-') as tmp:
        root = Path(tmp)
        (root/'request.json').write_text(json.dumps(request))
        result = subprocess.check_output(['ucode', '-L', lib, '-e', ucode, str(root/'request.json')])
        resolved = json.loads(result)['rule']
        for case, expected in [('old', 'final-out'), ('fixed', 'DE-out'),
                               ('outside', 'final-out'), ('source', 'final-out'),
                               ('port', 'final-out'), ('priority', 'earlier-out'),
                               ('disabled', 'final-out'), ('fakeip', 'DE-out')]:
            socks, dns_port = port(), port()
            lookup, route = dict(resolved), dict(request['rule'])
            domain = 'outside.example' if case == 'outside' else 'unlisted.example'
            if case == 'old':
                lookup['rule_set'] = route['rule_set']
            if case == 'source':
                lookup['source_ip_cidr'] = route['source_ip_cidr'] = ['192.0.2.0/24']
            if case == 'port':
                lookup['port'] = route['port'] = [target_port % 65535 + 1]
            rules = [{'inbound': ['dns-in'], 'action': 'sniff'},
                     {'protocol': 'dns', 'action': 'hijack-dns'}]
            if case == 'priority':
                rules.append({'domain': [domain], 'action': 'route', 'outbound': 'earlier-out'})
            if case != 'disabled':
                rules.append(lookup)
            rules.append(route)
            config = {
                'log': {'level': 'debug', 'timestamp': False},
                'dns': {'servers': [
                    {'type': 'hosts', 'tag': 'dns-server', 'predefined': {
                        'unlisted.example': ['127.0.0.2'], 'outside.example': ['127.0.0.3']}},
                    {'type': 'fakeip', 'tag': 'fakeip', 'inet4_range': '198.18.0.0/15'}],
                    'rules': [{'inbound': ['dns-in'], 'action': 'route', 'server': 'fakeip'}],
                    'final': 'dns-server', 'strategy': 'ipv4_only'},
                'inbounds': [{'type': 'socks', 'tag': 'tproxy-in', 'listen': '127.0.0.1', 'listen_port': socks},
                             {'type': 'direct', 'tag': 'dns-in', 'listen': '127.0.0.1', 'listen_port': dns_port}],
                'outbounds': [{'type': 'direct', 'tag': tag} for tag in ['DE-out', 'final-out', 'earlier-out']],
                'route': {'rules': rules, 'final': 'final-out', 'default_domain_resolver': 'dns-server',
                          'rule_set': [
                              {'type': 'inline', 'tag': 'domain-list', 'rules': [{'domain': ['listed.example']}]},
                              {'type': 'inline', 'tag': 'ip-list', 'rules': [{'ip_cidr': ['127.0.0.2/32']}]}]},
            }
            file, log = root/'config.json', root/'core.log'
            file.write_text(json.dumps(config))
            with log.open('w') as output:
                core = subprocess.Popen(['sing-box', 'run', '-c', str(file)], stdout=output, stderr=output)
                try:
                    for _ in range(60):
                        assert core.poll() is None, log.read_text()
                        try:
                            with socket.create_connection(('127.0.0.1', socks), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.05)
                    proxy = '--socks5-hostname'
                    if case == 'fakeip':
                        domain = subprocess.check_output(['dig', '@127.0.0.1', '-p', str(dns_port),
                                                          domain, 'A', '+short', '+tcp', '+tries=1', '+timeout=2'], text=True).strip()
                        assert domain.startswith(('198.18.', '198.19.')), domain
                        proxy = '--socks5'
                    data = subprocess.check_output(['curl', '--noproxy', '', '-fsS', '--max-time', '5',
                                                    proxy, f'127.0.0.1:{socks}', f'http://{domain}:{target_port}/'])
                    assert data == b'route-ip-resolve-ok', (case, data)
                finally:
                    core.terminate()
                    core.wait(timeout=5)
            text = log.read_text()
            assert f'outbound/direct[{expected}]' in text, (case, expected, text)
            for tag in ['DE-out', 'final-out', 'earlier-out']:
                if tag != expected:
                    assert f'outbound/direct[{tag}]' not in text, (case, tag, text)
            print(f'PASS {case}: actual outbound {expected}')
finally:
    server.shutdown()
    server.server_close()
