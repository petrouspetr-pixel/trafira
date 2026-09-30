#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
node - "$ROOT_DIR/trafira/files/usr/lib/components/updates.uc" "$WORK_DIR/test.uc" <<'NODE'
const fs = require('fs');
const [sourcePath, target] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const names = ['domain_ip_list_ruleset_path','reset_domain_ip_list_ruleset','cleanup_empty_ruleset',
  'add_plain_subnet_file_to_nft_for_section','import_domain_ip_list_file_into_rulesets',
  'import_domain_ip_list_reference_into_rulesets','rebuild_domain_ip_lists_from_rule'];
const bodies = names.map(name => {const start=source.indexOf(`function ${name}(`);if(start<0)throw Error(name);return {start,code:source.slice(start,source.indexOf('\n}',start)+2)};}).sort((a,b)=>a.start-b.start);
fs.writeFileSync(target, `
let fs = require("fs");
const TMP_RULESET_FOLDER = ARGV[0];
const NFT_TABLE_NAME="test", NFT_COMMON_SET_NAME="test", NFT_IP_PORT_SET_NAME="test", NFT_COMMON6_SET_NAME="test", NFT_IP_PORT6_SET_NAME="test";
let as_string = v => v == null ? "" : "" + v;
let bool_option = (obj,key,fallback) => obj[key] == null ? fallback : !!obj[key];
let option = (obj,key,fallback) => obj[key] == null ? fallback : obj[key];
let list_option_values = (obj,key) => obj[key] || [];
let section_name = s => s.name;
let owner_pid = () => "100";
let counter = 0;
let temp_path = () => TMP_RULESET_FOLDER + "/temp-" + (++counter);
let ensure_dir = p => true;
let file_exists_value = p => fs.stat(p) != null;
let file_nonempty = p => length(fs.readfile(p) || "") > 0;
let write_file = (p,s) => fs.writefile(p,s) != null;
let remove_file = p => fs.unlink(p);
let remove_files = paths => { for (let p in paths) fs.unlink(p); };
let copy_file = (a,b) => fs.writefile(b,fs.readfile(a)) != null;
let log_message = (s,l) => null;
let service_proxy_address = (s,k) => "";
let convert_crlf_to_lf = p => true;
let download_to_file = (url,p,proxy) => {
    if (url == "https://fail.test/list") return false;
    return fs.writefile(p, "new.example\\n203.0.113.0/24\\n") != null;
};
let routing_rulesets_module = () => ({ruleset_tag: (name,a,b) => name, has_rules: p => length(json(fs.readfile(p)).rules) > 0});
let fail_import = false;
let ruleset_module_success = args => {
    if (args[0] == "create-source") return fs.writefile(args[1], '{"version":3,"rules":[]}') != null;
    if (args[0] == "import-plain-list") {
        if (fail_import) return false;
        let data = json(fs.readfile(args[2]));
        let text = trim(fs.readfile(args[1]) || "");
        if (text != "") { let rule={}; rule[args[3]]=split(text,"\\n"); push(data.rules,rule); }
        return fs.writefile(args[2],sprintf("%J",data)) != null;
    }
    return false;
};
let nft_calls = 0;
let empty_parse = false;
let fail_nft = false;
let nft_module_success = args => {
    if (args[0] == "split-domain-subnet-file") {
        if (empty_parse) { fs.writefile(args[2],""); fs.writefile(args[3],""); return true; }
        fs.writefile(args[2],"new.example\\n"); fs.writefile(args[3],"203.0.113.0/24\\n"); return true;
    }
    nft_calls++; return !fail_nft;
};
function check(ok,message) { if (!ok) { warn("FAIL: "+message+"\\n"); exit(1); } }
` + bodies.map(b=>b.code).join('\n') + `
let section={name:"alpha",enabled:true,action:"connection",domain_ip_lists:["https://good.test/list","https://fail.test/list"]};
let path=domain_ip_list_ruleset_path(section);
let old='{"version":3,"rules":[{"domain_suffix":["old.example"]}]}';
fs.writefile(path,old);
check(!rebuild_domain_ip_lists_from_rule(section,{}),"failed download must report failure");
check(fs.readfile(path)==old,"partial download overwrote previous working list");
check(nft_calls==0,"failed replacement changed live nft sets");
section.domain_ip_lists=[TMP_RULESET_FOLDER+"/missing-local.txt"];
check(!rebuild_domain_ip_lists_from_rule(section,{}),"missing local source must fail");
check(fs.readfile(path)==old,"missing local source erased prior list");
section.domain_ip_lists=["https://good.test/list"];
empty_parse=true;
check(!rebuild_domain_ip_lists_from_rule(section,{}),"HTTP-success source without valid entries must fail");
check(fs.readfile(path)==old && nft_calls==0,"invalid source erased previous rules");
empty_parse=false;
fail_import=true;
check(!rebuild_domain_ip_lists_from_rule(section,{}),"failed import must report failure");
check(fs.readfile(path)==old && nft_calls==0,"failed import changed live rules");
fail_import=false;
let real_rename=fs.rename;
fs.rename=(a,b)=>false;
check(!rebuild_domain_ip_lists_from_rule(section,{}),"failed publication must report failure");
check(fs.readfile(path)==old && nft_calls==0,"failed rename modified live rules");
fs.rename=real_rename;
check(rebuild_domain_ip_lists_from_rule(section,{}),"successful replacement failed");
check(index(fs.readfile(path),"new.example")>=0 && index(fs.readfile(path),"old.example")<0,"replacement must not retain old entries");
check(nft_calls==1,"successful replacement should apply collected subnets once");
fs.writefile(path,old);
fail_nft=true;
check(!rebuild_domain_ip_lists_from_rule(section,{}),"failed nft application must report failure");
check(fs.readfile(path)==old,"failed nft application discarded previous materialized rules");
fail_nft=false;
section.action="dns";
nft_calls=0;
fs.writefile(path,old);
check(rebuild_domain_ip_lists_from_rule(section,{}),"DNS-only replacement failed");
check(index(fs.readfile(path),"new.example")>=0,"DNS-only replacement did not publish domains");
check(nft_calls==0,"DNS-only replacement must not change nft sets");
print("List replacement safety checks passed\\n");
`);
NODE
ucode "$WORK_DIR/test.uc" "$WORK_DIR"
