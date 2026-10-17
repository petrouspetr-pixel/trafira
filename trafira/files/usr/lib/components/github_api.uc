// Shared RAM-only GitHub API cooldown. Failed/stale metadata never authorizes installs.
let fs=require("fs");
const ROOT=getenv("TRAFIRA_RUNTIME_STATE_DIR")||"/var/run/trafira";
const STATE=ROOT+"/github-api-limit.json";
function quote(value){return "'"+replace(""+value,/'/g,"'\\''")+"'";}
function read(path,limit){
    let info=fs.lstat(path);
    if(!info || info.type!="file" || info.size>limit)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let text=file.read(limit+1);file.close();
    return text!=null && length(text)<=limit?text:null;
}
function cooldown(now){
    let value;
    try{value=json(read(STATE,1024));}catch(e){return null;}
    return type(value)=="object" && type(value.created_at)=="int" && type(value.retry_at)=="int" &&
        now>=value.created_at && value.retry_at>now && value.retry_at<=value.created_at+3600?
        {success:false,error:"github_rate_limited",retry_at:value.retry_at}:null;
}
function save_limit(now,retry){
    let path=STATE+sprintf(".%x-%x",clock()[0],clock()[1]);
    let file=fs.open(path,"wex",384);if(!file)return;
    let text=sprintf("%J",{created_at:now,retry_at:retry}),ok=file.write(text)==length(text);
    file.close();if(ok)fs.rename(path,STATE);fs.unlink(path);
}
function request(url,proxy,maximum,seconds,now){
    if(type(url)!="string" || !match(url,/^https:\/\/api[.]github[.]com\/repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/releases(\/latest|\/tags\/[A-Za-z0-9_+-][A-Za-z0-9_.+-]{0,199}|[?]per_page=[0-9]+(&page=[0-9]+)?)?$/))
        return {success:false,error:"invalid_github_url"};
    now=now==null?clock()[0]:now;
    let wait=cooldown(now);if(wait)return wait;
    let parent=fs.lstat(ROOT);
    if(parent?parent.type!="directory":!fs.mkdir(ROOT,493))return {success:false,error:"storage_unavailable"};
    let dir=ROOT+sprintf("/github-query-%x-%x",clock()[0],clock()[1]);
    if(!fs.mkdir(dir,448))return {success:false,error:"storage_unavailable"};
    maximum=min(8*1024*1024,max(1,maximum||2097152));seconds=min(30,max(1,seconds||20));
    let body=dir+"/body",headers=dir+"/headers";
    let args=["curl","--connect-timeout","5","--max-time",""+seconds,"--max-filesize",""+maximum,
        "--proto","=https","--proto-redir","=https","--fail-with-body","-sSL","--dump-header",headers];
    if(proxy)push(args,"--proxy","http://"+proxy,"--noproxy","");
    else push(args,"--noproxy","*");
    push(args,url,"-o",body);
    let status=system("exec "+join(" ",map(args,quote))+" </dev/null >/dev/null 2>&1",(seconds+1)*1000);
    let raw=read(body,maximum),head=read(headers,32768),code=status==0?200:0,fields={};
    for(let line in split(head||"","\n")) {
        let found=match(trim(line),/^HTTP\/[^ ]+ ([0-9]{3})/);
        if(found){code=int(found[1]);fields={};continue;}
        let colon=index(line,":");
        if(colon>0)fields[lc(trim(substr(line,0,colon)))]=trim(substr(line,colon+1));
    }
    fs.unlink(body);fs.unlink(headers);fs.rmdir(dir);
    let limited=code==429 || (code==403 && (fields["x-ratelimit-remaining"]=="0" || fields["retry-after"] ||
        match(lc(substr(raw||"",0,4096)),/rate limit/)));
    if(limited){
        let retry=now+60;
        if(match(fields["retry-after"]||"",/^[0-9]+$/))retry=now+int(fields["retry-after"]);
        else if(match(fields["x-ratelimit-reset"]||"",/^[0-9]+$/))retry=int(fields["x-ratelimit-reset"]);
        retry=min(now+3600,max(now+1,retry));save_limit(now,retry);
        return {success:false,error:"github_rate_limited",retry_at:retry};
    }
    if(status!=0 || code<200 || code>=300 || raw==null)return {success:false,error:"github_request_failed"};
    try{let value=json(raw);if(index(["object","array"],type(value))<0)return {success:false,error:"github_invalid_response"};}
    catch(e){return {success:false,error:"github_invalid_response"};}
    return {success:true,body:raw};
}
return {request,cooldown};
