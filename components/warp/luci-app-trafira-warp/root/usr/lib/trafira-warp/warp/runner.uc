// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),transport=require("warp.transport"),job=require("warp.job");
let c=state.load(state.DIRECTORY+"/transport.json");
if(!c || c.enabled!==true || !transport.valid_config(c))exit(1);
let cursor=require("uci").cursor();
if(!transport.owned(cursor.get_all("network",c.interface),c.interface) || fs.stat("/sys/class/net/"+c.interface))exit(1);
// Keep the supervisor as a direct popen child. Parent-death cleanup owns the
// whole AWG group even when procd has to kill this runner.
let metadata=state.RUNTIME+"/daemon.json";
if(!state.ensure(state.RUNTIME) || !state.remove(metadata))exit(1);
let command="TRAFIRA_WARP_PIDFILE="+transport.quote(metadata)+" exec /usr/libexec/trafira-warp-exec 0 "+transport.quote(state.RUNTIME+"/daemon-cancel.json")+" daemon /usr/libexec/trafira-warp-amneziawg-go -f "+transport.quote(c.interface)+" 2>/dev/null";
let pipe=fs.popen(command,"re");if(!pipe)exit(1);
let identity=null;
for(let n=0;n<20;n++) {
    identity=state.load(metadata);if(identity && job.live(identity))break;
    system("sleep 0.1");
}
if(!identity || !job.live(identity) || !state.save(state.RUNTIME+"/transport.json",{worker:identity,generation:c.generation}))exit(1);
let pid=identity.pid;
let ready=false;
for(let n=0;n<15;n++) {
    if(!job.live(identity))exit(1);
    if(fs.lstat("/var/run/amneziawg/"+c.interface+".sock") && fs.stat("/sys/class/net/"+c.interface)){ready=true;break;}
    system("sleep 1");
}
let success=ready && transport.output(["/usr/libexec/trafira-warp-awgctl","setconf",c.interface,state.DIRECTORY+"/awg.conf"])!=null;
let enabled6=trim(fs.readfile("/proc/sys/net/ipv6/conf/all/disable_ipv6")||"1")!="1";
if(success)for(let args in transport.address_commands(c,enabled6))if(transport.output(args)==null)success=false;
if(success)success=transport.output(["ip","link","set","dev",c.interface,"mtu",""+c.mtu,"up"])!=null;
if(success)success=transport.route_setup(c);
if(!success){if(job.live(identity))system("kill -TERM "+pid);exit(1);}
pipe.close();
exit(1);
