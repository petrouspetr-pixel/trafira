"""Real userspace-AWG, UAPI, runner and sing-box in isolated CI namespaces."""
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess as sp
import tempfile
import time
ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'trafira/files/usr/lib'
BIN = '/usr/libexec/trafira-warp-amneziawg-go'
CTL = '/usr/libexec/trafira-warp-awgctl'
assert os.geteuid() == 0 and os.environ.get('RUN_TRAFIRA_WARP_NETWORK_TESTS') == '1'
work = Path(tempfile.mkdtemp(prefix='trafira-warp-network.'))
router, server, client = [f'tf-warp-{v}-{os.getpid()}' for v in ['r', 's', 'c']]
processes = []
logs = []
def run(args, ns=None, data=None, check=True):
    command = (['ip', 'netns', 'exec', ns] if ns else []) + list(map(str, args))
    result = sp.run(command, input=data, text=True, capture_output=True, timeout=30)
    if check and result.returncode:
        raise AssertionError(f'{command[:6]} exited {result.returncode}: {result.stderr[-1500:]}')
    return result

def start(args, ns, label):
    log = open(work / (label + '.log'), 'w'); logs.append(log)
    p = sp.Popen(['ip', 'netns', 'exec', ns, *map(str, args)], stdout=log, stderr=log)
    processes.append(p); return p

def ip(ns, *args): return run(['ip', *args], ns)
def uc(code, ns=router):
    return run(['ucode', '-L', LIB, '-L', work/'addon', '-e', code], ns).stdout.strip()
def nft(text): return run(['nft', '-f', '-'], router, text)
def wait(predicate, label):
    for _ in range(100):
        if predicate(): return
        time.sleep(.1)
    raise AssertionError('Timed out: '+label)
def uapi(iface, text):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5);sock.connect('/var/run/amneziawg/'+iface+'.sock')
        sock.sendall(('set=1\n'+text+'\n\n').encode())
        response=sock.recv(65536)
        assert b'errno=0' in response, response

def curl(ns=router, address='198.51.100.2', source=None, success=True):
    args=['curl','--noproxy','*','--max-time','3','-fsS']
    if source: args += ['--interface',source]
    result=run(args+['http://'+address+':18080/'], ns, check=False)
    assert (result.returncode==0)==success,(ns,address,source,result.stderr)

def counters_zero():
    counters=json.loads(run(['nft','-j','list','counters','table','inet','Audit'],router).stdout)
    values=[v['counter'] for v in counters['nftables'] if 'counter' in v]
    assert len(values)==3 and all(v['packets']==0 for v in values),values

def base_rules():
    nft("""add table inet WarpTest
flush table inet WarpTest
add set inet WarpTest local4 { type ipv4_addr; flags interval; elements = { 127.0.0.0/8, 192.0.2.0/24 }; }
add set inet WarpTest local6 { type ipv6_addr; flags interval; elements = { ::1/128, fe80::/10, 2001:db8:2::/64 }; }
add chain inet WarpTest mangle_output { type route hook output priority -150; policy accept; }
add chain inet WarpTest proxy { type filter hook prerouting priority -100; policy accept; }
add rule inet WarpTest proxy ip daddr @local4 return
add rule inet WarpTest proxy ip6 daddr @local6 return
add rule inet WarpTest proxy iifname "lan" ip saddr 192.0.2.2 meta l4proto { tcp, udp } meta mark set 0x04000000 tproxy ip to 127.0.0.1:1602 accept
add rule inet WarpTest proxy iifname "lan" ip6 saddr 2001:db8:2::2 meta l4proto { tcp, udp } meta mark set 0x04000000 tproxy ip6 to [::1]:1603 accept
""")

try:
    for ns in [router,server,client]:run(['ip','netns','add',ns]);ip(ns,'link','set','lo','up')
    for left,right,leftns,rightns in [('wan','peer',router,server),('lan','client',router,client)]:
        run(['ip','link','add',left,'type','veth','peer','name',right]);run(['ip','link','set',left,'netns',leftns]);run(['ip','link','set',right,'netns',rightns])
        ip(leftns,'link','set',left,'up');ip(rightns,'link','set',right,'up')
    for ns,dev,v4,v6 in [(router,'wan','162.159.192.2/24','2001:db8:1::1/64'),(server,'peer','162.159.192.1/24','2001:db8:1::2/64'),(router,'lan','192.0.2.1/24','2001:db8:2::1/64'),(client,'client','192.0.2.2/24','2001:db8:2::2/64')]:
        ip(ns,'addr','add',v4,'dev',dev);ip(ns,'-6','addr','add',v6,'dev',dev,'nodad')
    ip(client,'addr','add','192.0.2.3/24','dev','client');ip(client,'-6','addr','add','2001:db8:2::3/64','dev','client','nodad')
    ip(client,'route','add','default','via','192.0.2.1');ip(client,'-6','route','add','default','via','2001:db8:2::1')
    ip(server,'addr','add','198.51.100.2/32','dev','lo')
    ip(server,'addr','add','1.1.1.1/32','dev','lo')
    ip(server,'route','add','192.0.2.0/24','via','162.159.192.2');ip(server,'-6','route','add','2001:db8:2::/64','via','2001:db8:1::1')
    ip(router,'route','add','default','via','162.159.192.1')
    ip(router,'-6','route','add','default','via','2001:db8:1::2')
    run(['sysctl','-qw','net.ipv4.ip_forward=1','net.ipv6.conf.all.forwarding=1','net.ipv4.conf.all.rp_filter=0','net.ipv4.conf.wan.rp_filter=0','net.ipv4.conf.lo.rp_filter=0','net.ipv4.conf.all.route_localnet=1'],router)
    for family in ['-4','-6']:
        ip(router,family,'rule','add','pref','105','fwmark','0x04000000/0x04000000','table','200')
        ip(router,family,'route','add','local','default','dev','lo','table','200')
    for name in ['state','run','runtime','addon']:(work/name).mkdir(mode=0o700)
    shutil.copytree(ROOT/'components/warp/luci-app-trafira-warp/root/usr/lib/trafira-warp/warp',work/'addon/warp')
    (work/'uci').write_text('')
    (work/'addon/uci.uc').write_text('let t=require("warp.transport");return {cursor:()=>({get_all:(pkg,name)=>name=="tfwarp0"?{".type":"interface",...t.network_section(name)}:null})};')
    os.environ.update(TRAFIRA_WARP_STATE=str(work/'state'),TRAFIRA_WARP_RUNTIME=str(work/'run'),TRAFIRA_RUNTIME_STATE_DIR=str(work/'runtime'),TRAFIRA_LIB=str(LIB),TRAFIRA_WARP_LIB=str(work/'addon'),TRAFIRA_UCI_STATE_FILE=str(work/'uci'))
    priv1=run(['wg','genkey']).stdout.strip();priv2=run(['wg','genkey']).stdout.strip()
    pub1=run(['wg','pubkey'],data=priv1+'\n').stdout.strip();pub2=run(['wg','pubkey'],data=priv2+'\n').stdout.strip()
    daemon=start([BIN,'-f','tfwarp9'],server,'awg-server')
    wait(lambda:Path('/var/run/amneziawg/tfwarp9.sock').exists(),'server UAPI')
    uapi('tfwarp9','private_key='+base64.b64decode(priv2).hex()+'\nlisten_port=2408\njc=5\njmin=10\njmax=50\npublic_key='+base64.b64decode(pub1).hex()+'\nallowed_ip=172.16.0.2/32\nallowed_ip=fd42::2/128')
    ip(server,'addr','add','172.16.0.1/32','dev','tfwarp9');ip(server,'-6','addr','add','fd42::1/128','dev','tfwarp9','nodad')
    ip(server,'link','set','tfwarp9','mtu','1280','up');ip(server,'route','add','172.16.0.2/32','dev','tfwarp9');ip(server,'-6','route','add','fd42::2/128','dev','tfwarp9')
    config=dict(interface='tfwarp0',endpoint='162.159.192.1:2408',fwmark=134217728,mtu=1280,ipv4='172.16.0.2',ipv6='fd42::2',private_key=priv1,peer_public_key=pub2,jc=5,jmin=10,jmax=50,i1='<b 0x01>',enabled=True,generation=1)
    (work/'state/transport.json').write_text(json.dumps(config));os.chmod(work/'state/transport.json',0o600)
    uc('let s=require("warp.state"),t=require("warp.transport");assert(s.save_text(s.DIRECTORY+"/awg.conf",t.config_text(s.load(s.DIRECTORY+"/transport.json"))),"private config");')
    runner=start(['ucode','-L',LIB,'-L',work/'addon',work/'addon/warp/runner.uc'],router,'awg-runner')
    wait(lambda:json.loads(uc('print(sprintf("%J",require("warp.transport").status()));')).get('running'),'verified runner ownership')
    snapshot=json.loads(uc('print(sprintf("%J",require("nft.router_origin").snapshot({},[{".name":"warp","action":"connection","enabled":"1","interfaces":["tfwarp0"]}])));'))
    assert snapshot is not None and snapshot.get('warp'), 'Userspace WARP bootstrap must be recognized'
    assert snapshot['vpn']==[] and snapshot['vpn_ports']==[],snapshot
    # A real UAPI handshake followed by HTTP over both tunnel address families.
    run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=warp.test','-addext','subjectAltName=DNS:warp.test,IP:1.1.1.1,IP:198.51.100.2','-keyout',work/'tls.key','-out',work/'tls.crt'])
    os.environ['CURL_CA_BUNDLE']=str(work/'tls.crt')
    start(['python3',ROOT/'tests/helpers/warp_servers.py',work/'tls.crt',work/'tls.key'],server,'http')
    time.sleep(.5)
    assert json.loads(uc('print(sprintf("%J",require("warp.stability").health("tfwarp0","fixture")));'))['warp'],'verified HTTPS over real AWG'

    start(['python3','-m','http.server','18080','--bind','192.0.2.1','--directory',work],router,'management')
    config={'log':{'level':'error'},'inbounds':[{'type':'tproxy','tag':'lan4','listen':'127.0.0.1','listen_port':1602},{'type':'tproxy','tag':'lan6','listen':'::1','listen_port':1603}], 'outbounds':[{'type':'direct','tag':'vpn-out','bind_interface':'tfwarp0'}], 'route':{'rules':[{'action':'sniff','inbound':['lan4','lan6','dns-test']}],'default_mark':134217728,'final':'vpn-out'}, 'dns':{'servers':[],'rules':[]}}
    config['inbounds'].append({'type':'direct','tag':'dns-test','listen':'127.0.0.42','listen_port':53})
    config['route']['rules'].append({'action':'hijack-dns','protocol':'dns'})
    config['route']['default_domain_resolver']='dns-server'
    config['dns']={'servers':[{'type':'udp','tag':'dns-server','server':'198.51.100.2','detour':'vpn-out'},{'type':'fakeip','tag':'fakeip','inet4_range':'198.18.0.0/15','inet6_range':'fc00::/18'}], 'rules':[{'inbound':'dns-test','query_type':['A','AAAA'],'server':'fakeip'}], 'final':'dns-server'}
    (work/'base.json').write_text(json.dumps(config))
    uc('let fs=require("fs"),r=require("config.router_origin"),c=json(fs.readfile("'+str(work/'base.json')+'"));r.attach(c,{router_origin_enabled:"1",router_origin_section:"vpn"},[{".name":"vpn",action:"connection"}]);require("core.common").strip_internal_fields(c);fs.writefile("'+str(work/'router.json')+'",sprintf("%J",c));')
    run(['sing-box','check','-c',work/'router.json'],router)
    core=start(['sing-box','run','-c',work/'router.json'],router,'sing-box');time.sleep(.6)
    base_rules()
    nft('''table inet Audit {
 counter direct4 {}
 counter direct6 {}
 counter plain_peer {}
 chain egress { type filter hook postrouting priority 0; policy accept;
 oifname "wan" ip daddr { 198.51.100.2, 1.1.1.1 } meta l4proto { tcp, udp } th dport { 53, 443, 18080, 18443 } counter name direct4
 oifname "wan" ip6 daddr 2001:db8:1::2 tcp dport 18080 counter name direct6
 oifname "wan" ip daddr 162.159.192.1 udp dport { 2408, 2409 } meta mark 0 counter name plain_peer
 }
 }''')
    # Ordinary LAN traffic retains its direct path; protected LAN uses WARP.
    curl(client,source='192.0.2.3');curl(client,'[2001:db8:1::2]',source='2001:db8:2::3')
    run(['nft','reset','counters','table','inet','Audit'],router)
    curl(client,source='192.0.2.2');curl(client,'[2001:db8:1::2]',source='2001:db8:2::2');counters_zero()
    run(['curl','--noproxy','*','--interface','192.0.2.2','--cacert',work/'tls.crt','--max-time','3','--resolve','warp.test:18443:198.51.100.2','-fsS','https://warp.test:18443/'],client);counters_zero()
    watchdog=start(['sh',ROOT/'components/warp/luci-app-trafira-warp/root/usr/libexec/trafira-warp-watchdog'],router,'watchdog')
    time.sleep(.1);watchdog.kill();watchdog.wait(timeout=5)
    curl(client,source='192.0.2.2');counters_zero()
    # Router-origin off is direct, on is bound to WARP with no broad UDP bypass.
    curl();run(['nft','reset','counters','table','inet','Audit'],router)
    origin=uc('print(require("config.router_origin").nft("WarpTest","local4","local6","0x04000000",{dns:[],ntp:[],vpn:[],vpn_ports:[]}));')
    nft(origin);curl();curl(address='[2001:db8:1::2]');counters_zero()
    dns_query="import socket,struct;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);q=struct.pack('!HHHHHH',123,256,1,0,0,0)+b'\\x04warp\\x04test\\x00'+struct.pack('!HH',1,1);s.sendto(q,('127.0.0.42',53));a=s.recv(2048);print(socket.inet_ntoa(a[-4:]))"
    fake=run(['python3','-c',dns_query],router).stdout.strip()
    assert fake.startswith('198.18.') or fake.startswith('198.19.'),fake
    def fake_request(success):
        result=run(['curl','--noproxy','*','--max-time','3','-fsS','--resolve','warp.test:18080:'+fake,'http://warp.test:18080/'],router,check=False)
        assert (result.returncode==0)==success,result.stderr
    fake_request(True);counters_zero()

    run(['python3','-c',"import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.sendto(b'ordinary-app',('162.159.192.1',2408))"],router);time.sleep(.3);counters_zero()
    # SIGKILL the actual runner: guardian must remove its TUN; nothing falls back.
    runner.kill();runner.wait(timeout=5)
    wait(lambda:ip(router,'-j','link','show').stdout.find('tfwarp0')<0,'supervisor removes tunnel after runner death')
    curl(success=False);curl(address='[2001:db8:1::2]',success=False);fake_request(False)
    curl(client,source='192.0.2.2',success=False);curl(client,'[2001:db8:1::2]',source='2001:db8:2::2',success=False);counters_zero()
    curl(client,address='192.0.2.1',source='192.0.2.2')
    inactive=json.loads(uc('print(sprintf("%J",require("nft.router_origin").snapshot({},[{".name":"warp",action:"connection",enabled:"1",interfaces:["tfwarp0"]}])));'))
    assert inactive and inactive['warp']['running'] is False,'inactive owned transport remains recognizable'
    core.terminate();core.wait(timeout=5)
    core=start(['sing-box','run','-c',work/'router.json'],router,'sing-box-cold');time.sleep(.6)
    assert core.poll() is None,'cold core must start with unavailable WARP'
    curl(client,source='192.0.2.2',success=False);counters_zero()
    # Restart the actual owned runner and its oif policy after abrupt loss.
    uapi('tfwarp9','listen_port=2409')
    uc('let s=require("warp.state"),t=require("warp.transport"),c=s.load(s.DIRECTORY+"/transport.json");c.endpoint="162.159.192.1:2409";c.generation++;assert(s.save(s.DIRECTORY+"/transport.json",c) && s.save_text(s.DIRECTORY+"/awg.conf",t.config_text(c)),"endpoint change");')
    runner=start(['ucode','-L',LIB,'-L',work/'addon',work/'addon/warp/runner.uc'],router,'awg-restart')
    wait(lambda:json.loads(uc('print(sprintf("%J",require("warp.transport").status()));')).get('running'),'runner restarts')
    curl(client,source='192.0.2.2');curl();counters_zero()
    # Interrupted nft rebuild protects selected connections, leaving management.
    guard=uc('print(require("service.runtime_apply").guard_script({source_network_interfaces:["lan"],router_origin_enabled:"1"},{},{}));')
    nft(guard);run(['nft','delete','table','inet','WarpTest'],router)
    curl(success=False);curl(client,source='192.0.2.2',success=False);counters_zero()
    curl(client,address='192.0.2.1',source='192.0.2.3')
    run(['nft','delete','table','inet','TrafiraReloadGuard'],router)
    runner.kill();runner.wait(timeout=5)
    wait(lambda:ip(router,'-j','link','show').stdout.find('tfwarp0')<0,'runner cleanup before IPv4-only')
    run(['sysctl','-qw','net.ipv6.conf.all.disable_ipv6=1','net.ipv6.conf.default.disable_ipv6=1'],router)
    runner=start(['ucode','-L',LIB,'-L',work/'addon',work/'addon/warp/runner.uc'],router,'awg-ipv4-only')
    wait(lambda:json.loads(uc('print(sprintf("%J",require("warp.transport").status()));')).get('running'),'IPv4-only runner')
    assert not json.loads(ip(router,'-j','-6','addr','show','dev','tfwarp0').stdout)[0].get('addr_info'),'no IPv6 address when globally disabled'
    run(['curl','--noproxy','*','--interface','tfwarp0','--max-time','3','-fsS','http://198.51.100.2:18080/'],router);counters_zero()
    print('WARP actual runner/UAPI, IPv4/IPv6 LAN, router-origin, peer UDP isolation, SIGKILL and fail-closed WAN counters passed')
except Exception:
    for file in work.glob('*.log'):
        print(file.name+': '+file.read_text(errors='replace')[-2000:])
    raise
finally:
    for ns in [router,server,client]:
        for pid in run(['ip','netns','pids',ns],check=False).stdout.split():
            run(['kill','-KILL',pid],check=False)
        run(['ip','netns','del',ns],check=False)
    for proc in processes:
        try:proc.wait(timeout=3)
        except sp.TimeoutExpired:proc.kill()
    for log in logs:log.close()
    for name in ['tfwarp0','tfwarp9']:
        Path('/var/run/amneziawg/'+name+'.sock').unlink(missing_ok=True)
    shutil.rmtree(work)
