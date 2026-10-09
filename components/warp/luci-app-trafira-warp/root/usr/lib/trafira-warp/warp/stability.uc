// SPDX-License-Identifier: Apache-2.0
let fs=require("fs"),state=require("warp.state"),transport=require("warp.transport"),process=require("warp.process"),job=require("warp.job");
const SERVICES={google:{host:"www.gstatic.com",path:"/generate_204"},chatgpt:{host:"chatgpt.com",path:"/"},gemini:{host:"gemini.google.com",path:"/"},grok:{host:"grok.com",path:"/"},cloudflare:{host:"cloudflare-dns.com",path:"/cdn-cgi/trace"}};
function valid_request(duration,services) {
    if(index([15,30,45,60],duration)<0 || type(services)!="array" || !length(services) || length(services)>5)return false;
    let seen={};for(let id in services){if(!SERVICES[id] || seen[id])return false;seen[id]=true;}
    return true;
}
function valid_address(ip) {
    if(!transport.ipv4(ip))return false;
    let a=map(split(ip,"."),(s)=>int(s));
    return a[0]>0 && a[0]<224 && a[0]!=10 && a[0]!=127 && !(a[0]==169 && a[1]==254) && !(a[0]==172 && a[1]>=16 && a[1]<=31) &&
        !(a[0]==192 && a[1]==168) && !(a[0]==100 && a[1]>=64 && a[1]<=127) && !(a[0]==198 && (a[1]==18 || a[1]==19));
}
function summarize(samples) {
    let times=[],errors=0,restricted=0;
    for(let sample in samples) {
        if(!sample.success)errors++;
        else if(type(sample.total)=="double" || type(sample.total)=="int")push(times,sample.total);
        if(index([403,429],sample.code)>=0)restricted++;
    }
    sort(times,(a,b)=>a-b);let n=length(times);
    let median=n?(n%2?times[int(n/2)]:(times[n/2-1]+times[n/2])/2):null;
    return {samples:length(samples),transport_errors:errors,http_restricted:restricted,median,p95:n?times[int((n*95+99)/100)-1]:null};
}
function curl(iface,url,id,extra) {
    return process.run(["curl","-4","--noproxy","*","--interface",iface,"--connect-timeout","5","--max-time","8","--silent","--show-error",...(extra||[]),url],8,id);
}
function probe(iface,service,id) {
    let entry=SERVICES[service];if(!entry || !transport.valid_interface(iface))return {service,success:false,error:"invalid_request"};
    let dns=curl(iface,"https://cloudflare-dns.com/dns-query?name="+entry.host+"&type=A",id,["--resolve","cloudflare-dns.com:443:1.1.1.1","--header","accept: application/dns-json"]);
    if(!dns.success)return {service,success:false,error:"dns_failed",code:0};
    let reply;try {reply=json(dns.text);}catch(e){return {service,success:false,error:"dns_failed",code:0};}
    let addresses=[];for(let answer in reply.Answer||[])if(answer.type==1 && valid_address(answer.data))push(addresses,answer.data);
    if(!length(addresses))return {service,success:false,error:"dns_empty",code:0};
    let result=curl(iface,"https://"+entry.host+entry.path,id,["--resolve",entry.host+":443:"+addresses[0],"--output","/dev/null","--write-out","%{http_code} %{time_total}"]);
    let parts=split(trim(result.text||"")," "),code=int(parts[0]||"0"),total=double(parts[1]||"0");
    return {service,success:result.success && code>=100,code,total,error:result.success?null:result.error};
}
function health(iface,id) {
    let result=curl(iface,"https://1.1.1.1/cdn-cgi/trace",id,["--fail"]);
    return {success:result.success,https_ok:result.success,warp:result.success && match(result.text,/(^|\n)warp=(on|plus)(\n|$)/)!=null};
}
function run(duration,services,id) {
    if(!valid_request(duration,services))return {success:false,error:"invalid_request"};
    let start=transport.status();if(!start.running)return {success:false,error:"transport_stopped"};
    let samples=[],started=clock()[0],end=started+duration*60,error=null,trace={};
    while(clock()[0]<end && length(samples)<2000) {
        if(job.cancelled(id)){error="cancelled";break;}
        let current=transport.status();if(!current.running || current.generation!=start.generation){error="transport_changed";break;}
        trace=health(start.interface,id);
        for(let service in services) {
            if(clock()[0]>=end)break;
            if(job.cancelled(id)){error="cancelled";break;}
            push(samples,{...probe(start.interface,service,id),at:clock()[0]});
            if(!state.save(state.RUNTIME+"/test.json",{job_id:id,running:true,generation:start.generation,started_at:started,samples,summary:summarize(samples),...trace}))return {success:false,error:"storage_unavailable"};
        }
        if(error)break;
        for(let n=0;n<5;n++){if(job.cancelled(id))break;system("sleep 1");}
    }
    state.save(state.RUNTIME+"/test.json",{job_id:id,running:false,generation:start.generation,started_at:started,samples,summary:summarize(samples),...trace,error});
    return {success:!error,error};
}
return {SERVICES,valid_request,valid_address,summarize,probe,health,run};
