"""Real TPROXY sockets, production nft rules, no Internet or user configuration."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'trafira/files/usr/lib'


class RestartNetwork(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='trafira-tproxy-restart-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.router = f'tfr-r-{os.getpid()}'
        self.client = f'tfr-c-{os.getpid()}'
        for ns in (self.router, self.client):
            subprocess.run(['ip', 'netns', 'add', ns], check=True)
            self.addCleanup(lambda n=ns: subprocess.run(['ip', 'netns', 'del', n], check=False))
            self.run_in(ns, ['ip', 'link', 'set', 'lo', 'up'])
        self.run_in(self.router, ['ip', 'link', 'add', 'lan', 'type', 'veth', 'peer', 'name', 'peer'])
        self.run_in(self.router, ['ip', 'link', 'set', 'peer', 'netns', self.client])
        for ns, dev, v4, v6 in [(self.router, 'lan', '192.0.2.1', '2001:db8::1'),
                                 (self.client, 'peer', '192.0.2.2', '2001:db8::2')]:
            self.run_in(ns, ['ip', 'addr', 'add', v4+'/24', 'dev', dev])
            self.run_in(ns, ['ip', '-6', 'addr', 'add', v6+'/64', 'dev', dev, 'nodad'])
            self.run_in(ns, ['ip', 'link', 'set', dev, 'up'])
        self.run_in(self.client, ['ip', 'route', 'add', 'default', 'via', '192.0.2.1'])
        self.run_in(self.client, ['ip', '-6', 'route', 'add', 'default', 'via', '2001:db8::1'])
        for family, address in [('-4', '198.18.0.10/32'), ('-6', '2001:2::10/128')]:
            self.run_in(self.router, ['ip', family, 'addr', 'add', address, 'dev', 'lo'])
            self.run_in(self.router, ['ip', family, 'rule', 'add', 'fwmark', '0x100000/0x100000', 'table', '100'])
            self.run_in(self.router, ['ip', family, 'route', 'add', 'local', 'default', 'dev', 'lo', 'table', '100'])
        self.procs = []
        self.addCleanup(self.stop_all)
        self.start(self.router, ['python3', '-u', '-c', '''
import socket,socketserver,threading,time
class Echo(socketserver.BaseRequestHandler):
 def handle(self):
  if isinstance(self.request,tuple): self.request[1].sendto(self.request[0],self.client_address);return
  while True:
   data=self.request.recv(65536)
   if not data:break
   self.request.sendall(data)
for family,host in [(socket.AF_INET,'198.18.0.10'),(socket.AF_INET6,'2001:2::10')]:
 for base in [socketserver.ThreadingTCPServer,socketserver.ThreadingUDPServer]:
  cls=type('Server',(base,),{'address_family':family,'allow_reuse_address':True,'daemon_threads':True})
  server=cls((host,443),Echo)
  threading.Thread(target=server.serve_forever,daemon=True).start()
print('ready',flush=True)
while True:time.sleep(1)
'''], 'echo', ready='ready')

    def run_in(self, ns, args, **kw):
        result = subprocess.run(['ip', 'netns', 'exec', ns, *args], check=False,
                                text=True, capture_output=True, timeout=15, **kw)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        return result

    def start(self, ns, args, name, ready=None):
        log = (self.work / (name+'.log')).open('w+')
        proc = subprocess.Popen(['ip', 'netns', 'exec', ns, *args], stdout=log, stderr=log)
        self.procs.append((proc, log))
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            log.flush()
            content = (self.work / (name+'.log')).read_text()
            if ready and ready in content: return proc
            if not ready and time.monotonic()>deadline-4.5 and proc.poll() is None: return proc
            if proc.poll() is not None: self.fail(content)
            time.sleep(.02)
        self.fail('process not ready: '+name)

    def stop_all(self):
        for proc, log in reversed(self.procs):
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            log.close()

    def close_client(self, proc):
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=5)

    def rules(self, enabled, selected=True):
        self.run_in(self.router, ['nft', 'delete', 'table', 'inet', 'TrafiraTable']) if getattr(self, 'table', False) else None
        fixture = self.work/'fixture.json'
        fixture.write_text(json.dumps({'settings': {'disable_quic': str(int(enabled))}, 'section': []}))
        self.run_in(self.router, ['ucode', '-L', str(LIB), str(LIB/'nft/apply.uc'),
            'nft-create-runtime-base-fixture', str(fixture), 'TrafiraTable', 'localv4',
            'subnets', 'ports', 'ip_ports', 'interfaces', 'lan' if selected else 'excluded', '0x00100000', '0x08000000',
            '198.18.0.0/15', '1602', '0'])
        self.table = True

    def core(self):
        path = self.work/'core.json'
        path.write_text(json.dumps({'log': {'level': 'debug'}, 'inbounds': [
            {'type': 'tproxy', 'tag': 'tproxy-in', 'listen': '0.0.0.0', 'listen_port': 1602},
            {'type': 'tproxy', 'tag': 'tproxy6-in', 'listen': '::1', 'listen_port': 1602}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'}],
            'route': {'final': 'direct', 'default_mark': 0x8000000}}))
        return self.start(self.router, ['sing-box', 'run', '-c', str(path)], 'core-'+str(len(self.procs)))

    def test_restart_socket_recovery_without_global_conntrack_flush(self):
        self.rules(False)
        for family in (4, 6):
            for shutdown in (signal.SIGTERM, signal.SIGKILL):
                with self.subTest(family=family, shutdown=shutdown):
                    core = self.core()
                    code = '''
import socket,time
s=socket.socket(socket.AF_INET if FAMILY==4 else socket.AF_INET6)
s.settimeout(3)
host='198.18.0.10' if FAMILY==4 else '2001:2::10'
s.connect((host,443));s.sendall(b'before');assert s.recv(6)==b'before'
print('connected',flush=True)
input()
start=time.monotonic()
try:
 s.sendall(b'after');data=s.recv(5);assert data==b'',repr(data)
except (ConnectionResetError,BrokenPipeError):pass
assert time.monotonic()-start<2,'stale connection was not closed promptly'
s.close()
s=socket.create_connection((host,443),timeout=3)
s.sendall(b'fresh');assert s.recv(5)==b'fresh'
print('recovered',flush=True)
'''.replace('FAMILY', str(family))
                    client = subprocess.Popen(['ip','netns','exec',self.client,'python3','-u','-c',code],
                                              stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                    self.addCleanup(self.close_client,client)
                    self.assertTrue(select.select([client.stdout],[],[],5)[0], 'client did not connect')
                    self.assertEqual(client.stdout.readline().strip(),'connected')
                    if shutdown == signal.SIGKILL:
                        # Reproduce a lost FIN/RST during the outage, rather than
                        # assuming SIGKILL suppresses the kernel's socket close.
                        self.run_in(self.router,['nft','-f','-'],input='add table inet LostClose\n'
                            'add chain inet LostClose output { type filter hook output priority -1; policy accept; }\n'
                            'add rule inet LostClose output tcp flags & (fin | rst) != 0 drop\n')
                    core.send_signal(shutdown);core.wait(timeout=5)
                    if shutdown == signal.SIGKILL:
                        host='198.18.0.10' if family==4 else '2001:2::10'
                        source='192.0.2.2' if family==4 else '2001:db8::2'
                        entries=self.run_in(self.router,['conntrack','-L','-f','ipv4' if family==4 else 'ipv6',
                            '-p','tcp','-s',source,'-d',host]).stdout
                        self.assertIn('ESTABLISHED',entries,'must reproduce the leftover conntrack entry')
                        self.run_in(self.router,['nft','delete','table','inet','LostClose'])
                    self.core()
                    out,err=client.communicate('\n',timeout=8)
                    self.assertEqual(client.returncode,0,err)
                    self.assertIn('recovered',out)
                    for p,_ in self.procs:
                        if p.poll() is None and 'sing-box' in p.args:
                            p.terminate();p.wait(timeout=5)

    def test_unknown_quic_udp_is_blocked_before_core_for_both_families(self):
        self.core()
        for enabled,selected in ((False,True), (True,True), (True,False), (False,True)):
            self.rules(enabled,selected)
            result=self.run_in(self.client,['python3','-c','''
import socket
for family,host in [(socket.AF_INET,'198.18.0.10'),(socket.AF_INET6,'2001:2::10')]:
 print('family',family,'blocked',BLOCK,flush=True)
 s=socket.socket(family,socket.SOCK_DGRAM);s.settimeout(2);s.connect((host,443))
 try:
  s.send(b'not-recognizable-as-quic');data=s.recv(100)
  assert not BLOCK and data==b'not-recognizable-as-quic','UDP/443 escaped rejection'
 except ConnectionRefusedError:assert BLOCK,'unexpected rejection when disabled'
 s.close()
'''.replace('BLOCK',str(enabled and selected))])
            self.assertEqual(result.returncode,0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
