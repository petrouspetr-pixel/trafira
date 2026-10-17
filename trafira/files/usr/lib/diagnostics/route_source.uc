// A strict source subset with the same meaning in the native and ucode matchers.
// Version support is proved separately by the current core, once per analysis.
let fs=require("fs"),ip=require("core.ip");
function candidate(path,limit){
    let info=fs.stat(path);
    if(!info || info.type!="file" || info.size<=0 || info.size>limit)return null;
    let file=fs.open(path,"re");if(!file)return null;
    let text=file.read(limit+1);file.close();
    if(text==null || length(text)>limit)return null;
    let data;try{data=json(text);}catch(e){return null;}
    if(type(data)!="object" || length(keys(data))!=2 || data.version!==3 ||
        type(data.rules)!="array" || !length(data.rules) || length(data.rules)>512)return null;
    let count=0;
    for(let rule in data.rules){
        if(type(rule)!="object" || length(keys(rule))!=1 || type(rule.ip_cidr)!="array" || !length(rule.ip_cidr))return null;
        for(let cidr in rule.ip_cidr){
            if(++count>65536 || type(cidr)!="string" || length(cidr)>64 || index(cidr,"\u0000")>=0)return null;
            let slash=index(cidr,"/");
            // Narrowing the accepted fast subset never rejects a source: other
            // representations (including mapped addresses) use the native codec.
            if(slash<1 || !match(substr(cidr,slash+1),/^(0|[1-9][0-9]{0,2})$/) ||
                (index(cidr,":")>=0 && index(cidr,".")>=0) || !ip.nft_ip_or_cidr(cidr))return null;
        }
    }
    return {data,bytes:info.size};
}
return {candidate};
