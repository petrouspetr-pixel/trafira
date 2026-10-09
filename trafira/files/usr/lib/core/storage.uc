let fs=require("fs");
function available_bytes(path) {
    let quoted="'"+replace(""+path,/'/g,"'\\''")+"'";
    let pipe=fs.popen("df -P -k "+quoted+" 2>/dev/null","re");
    if(!pipe)return -1;
    let output=pipe.read(8193),status=pipe.close();
    if(status!=0 || output==null || length(output)>8192)return -1;
    let last="";
    for(let line in split(output,"\n"))if(trim(line)!="")last=trim(line);
    let fields=split(last,/[ \t]+/);
    if(length(fields)<6 || !match(fields[3],/^[0-9]+$/))return -1;
    return int(fields[3],10)*1024;
}
return {available_bytes};
