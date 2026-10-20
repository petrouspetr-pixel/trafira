#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" "$WORK_DIR" <<'NODE'
const fs=require('fs');
const [file,dir]=process.argv.slice(2),source=fs.readFileSync(file,'utf8');
function body(name) {const a=source.indexOf('function '+name+'('),b=source.indexOf('\nfunction ',a+1);if(a<0)throw Error(name);return source.slice(a,b).trim();}
const helpers=['as_string','shell_quote','command_from_args','command_status','command_success','command_success_from_args','command_output','command_output_from_args','remove_file','compressed_backup_digest','restore_ram_backup'].map(body).join('\n');
fs.writeFileSync(dir+'/test.uc',`
let fs=require("fs"),hash=require("singbox.provenance").hash_file;
let owner_pid=()=>123;
${helpers}
let root=ARGV[0],old=root+"/original",backup=root+"/old.gz",target=root+"/installed";
fs.writefile(old,"old working binary\\n"),fs.writefile(target,"failed new binary\\n");
assert(command_success(command_from_args(["gzip","-c",old])+" >"+shell_quote(backup)),"prepare compressed recovery");
assert(compressed_backup_digest(backup)==hash(old),"stream digest equals original");
assert(restore_ram_backup(target,backup,"0755"),"restore actual gzip payload");
assert(hash(target)==hash(old),"recovery bytes exact");
assert(fs.lstat(target).mode & 64,"restored binary executable");
assert(restore_ram_backup(target,backup,"0755"),"already restored payload needs no duplicate flash write");
assert(fs.stat(backup)!=null,"retain recovery until transaction complete");
fs.writefile(backup,"corrupt gzip"),fs.writefile(target,"working");
assert(compressed_backup_digest(backup)=="","reject corrupt recovery before touching target");
assert(!restore_ram_backup(target,backup,"0755"),"corrupt recovery fails safely");
assert(fs.readfile(target)=="working","working target preserved on invalid recovery");
print("Extended compressed RAM recovery passed\\n");
`);
NODE
ucode -L "$ROOT_DIR/trafira/files/usr/lib" "$WORK_DIR/test.uc" "$WORK_DIR"
