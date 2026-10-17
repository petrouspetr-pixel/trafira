// Read kernel-owned set definitions before an atomic rebuild. Nothing is
// published here: missing/incompatible/large snapshots use the normal updater.
let fs=require("fs");
function identifier(value){return type(value)=="string" && match(value,/^[a-zA-Z_][a-zA-Z0-9_]*$/);}
function kind(definition){
    let found=match(definition,/type[ \t]+([a-z0-9_ .]+)[;\r\n]/);
    return found?replace(trim(found[1]),/[ \t]+/g,""):null;
}
function load(table,definitions){
    if(!identifier(table) || type(definitions)!="object")return null;
    let result={},size=0;
    for(let name in keys(definitions)) {
        if(!identifier(name))return null;
        let pipe=fs.popen("exec nft -s list set inet "+table+" "+name+" 2>/dev/null","r");
        if(!pipe)return null;
        let text=pipe.read(524289),status=pipe.close();
        if(status!=0 || text==null || length(text)>524288 || (size+=length(text))>524288)return null;
        text=trim(text);
        let marker="set "+name+" ",start=index(text,marker);
        if(start<0 || trim(substr(text,0,start))!="table inet "+table+" {" || substr(text,-1)!="}")return null;
        let body=trim(substr(text,start+length(marker),length(text)-start-length(marker)-1));
        if(substr(body,0,1)!="{" || substr(body,-1)!="}" || kind(body)!=kind(definitions[name]))return null;
        // Kernel output contains no nested set declarations; braces only
        // delimit the set and its elements. Reject incomplete dumps early.
        let depth=0;
        for(let i=0;i<length(body);i++) {
            let ch=substr(body,i,1);
            if(ch=="{")depth++;
            else if(ch=="}" && --depth<0)return null;
            if(depth==0 && i<length(body)-1)return null;
        }
        if(depth!=0)return null;
        result[name]=body;
    }
    return result;
}
return {load};
