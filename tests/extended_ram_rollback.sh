#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" "$WORK_DIR" <<'NODE'
const fs=require('fs');
const [file,dir]=process.argv.slice(2),source=fs.readFileSync(file,'utf8');
function body(name) {const a=source.indexOf('function '+name+'('),b=source.indexOf('\nfunction ',a+1);if(a<0)throw Error(name);return source.slice(a,b).trim();}
const stage=body('stage_ram_extended_backup').replaceAll('"/usr/bin/sing-box"','root+"/original"').replaceAll('"/usr/lib/libcronet.so"','root+"/missing-library"');
const helpers=['as_string','shell_quote','command_from_args','command_status','command_success','command_success_from_args','command_output','command_output_from_args','remove_file','path_basename','compressed_backup_digest','restore_ram_backup'].map(body).join('\n');
fs.writeFileSync(dir+'/test.uc',`
let fs=require("fs"),hash=require("singbox.provenance").hash_file;
let owner_pid=()=>123;
${helpers}
let mem_available_bytes=()=>1073741824;
let filesystem_available_bytes=()=>1073741824;
let ensure_tmp_download_capacity=()=>true;
let tmp_dir=ARGV[0],root=ARGV[0];
${stage}
let old=root+"/original",backup=root+"/old.gz",target=root+"/installed";
fs.writefile(old,"old working binary\\n"),fs.writefile(target,"failed new binary\\n");
fs.mkdir(root+"/recovery",448);
let saved={directory:root+"/recovery",files:[]};
assert(stage_ram_extended_backup(saved),"real streaming compressed recovery copy");
assert(length(saved.files)==1 && saved.files[0].digest==hash(old),"saved exact original digest");
backup=saved.files[0].backup;
mem_available_bytes=()=>33554432;
assert(!stage_ram_extended_backup({directory:root+"/recovery",files:[]}),"RAM reserve prevents backup allocation");
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
