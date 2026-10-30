let resolver=require("diagnostics.public_host");
let calls=[];
function query(host,kind,server) {
    push(calls,[host,kind,server]);
    return {status:0,output:kind=="A"?(server?";; status: NOERROR\n93.184.216.34":"198.18.0.2"):";; status: NOERROR\n2606:4700::1111"};
}
assert(resolver.resolve("router.example.org",["9.9.9.9"],query)=="2606:4700::1111 93.184.216.34","public answer replaces split DNS/FakeIP");
assert(length(calls)==2 && calls[0][2]=="9.9.9.9","configured public bootstrap used before local DNS");
calls=[];
let result=resolver.resolve("router.example.org",["9.9.9.9"],function(host,kind,server){push(calls,server);return server?{status:9,output:""}:{status:0,output:kind=="A"?"192.168.1.1":""};});
assert(result=="192.168.1.1" && calls[length(calls)-1]=="","local fallback after public transport failure");
calls=[];
result=resolver.resolve("missing.example.org",["9.9.9.9"],function(host,kind,server){assert(server!="","do not replace public NXDOMAIN with local answer");return {status:0,output:";; status: NXDOMAIN"};});
assert(result=="","NXDOMAIN is an answer, not a transport failure");
result=resolver.resolve("router.example.org",["9.9.9.9","8.8.8.8"],function(host,kind,server){return server=="9.9.9.9"?{status:0,output:";; status: SERVFAIL"}:{status:0,output:kind=="A"?"8.8.4.4":""};});
assert(result=="8.8.4.4","try next public server after SERVFAIL");
assert(resolver.resolve("[2606:4700::1111]",[],()=>{die("literal must not query DNS");})=="2606:4700::1111","IPv6 literal unchanged");
assert(resolver.resolve("192.168.1.1",[],()=>{die("literal must not query DNS");})=="192.168.1.1","private IP literal remains private");
result=resolver.resolve("router.example.org",["127.0.0.1","198.18.0.1","fd00::1"],function(host,kind,server){assert(server=="1.1.1.1","ignore non-public bootstrap addresses");return {status:0,output:kind=="A"?"1.0.0.1":""};});
assert(result=="1.0.0.1","public defaults when all bootstrap addresses are local");
print("public-host DNS selection and fallback checks passed\n");
