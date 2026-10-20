#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/core_candidate.uc" <<'JS'
const assert=require('node:assert/strict');
const source=require('fs').readFileSync(process.argv[2],'utf8');
const a=source.indexOf('function package_matches('),b=source.indexOf('\nfunction ',a+1);
const match=(s,r)=>s.match(r),replace=(s,r,x)=>s.replace(r,x);
eval(source.slice(a,b));
const c={variant:'extended',package_type:'apk',architecture:'aarch64_cortex-a53',version:'1.14.3-extended-2.7.3'};
assert(package_matches('sing-box-extended','1.14.3.2.7.3-r0',c.architecture,c),'real Extended APK version encoding');
assert(package_matches('sing-box-extended','1.14.3.2.7.3-r1',c.architecture,c));
assert(package_matches('sing-box-extended','1.14.3-extended-2.7.3-r0',c.architecture,c),'retain original producer format');
for(const bad of ['1.14.3.2.7.2-r0','1.14.4.2.7.3-r0','1.14.3.2.7.3.0-r0','1.14.3.2.7.3-r0-evil'])assert(!package_matches('sing-box-extended',bad,c.architecture,c),bad);
assert(!package_matches('sing-box','1.14.3.2.7.3-r0',c.architecture,c));
assert(!package_matches('sing-box-extended','1.14.3.2.7.3-r0','x86_64',c));
assert(!package_matches('sing-box-extended','1.14.3.2.7.3-r0',c.architecture,{...c,package_type:'ipk'}));

const action=require('fs').readFileSync(require('path').join(require('path').dirname(process.argv[2]),'action.uc'),'utf8');
function body(name){const start=action.indexOf('function '+name+'(');assert(start>=0,name);return action.slice(start,action.indexOf('\nfunction ',start+1));}
let install_failure_detail='';
eval(body('ram_prepare_failure'));
assert.equal(ram_prepare_failure('candidate','package_metadata_mismatch'),null);
assert.equal(install_failure_detail,'candidate/package_metadata_mismatch');
assert(body('prepare_ram_extended_update').includes('ram_prepare_failure("candidate", core.error'));
assert(body('install_sing_box_extended_package').includes('package_failure_message("Cannot prepare verified Extended rollback in RAM; running service was not changed")'));
console.log('Extended APK version encoding and preflight diagnostics passed');
JS
