#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" <<'NODE'
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('function action_fail(');
const body = source.slice(start, source.indexOf('\n}', start) + 2);
for (const selected of [null, {action:'install'}]) {
  let result;
  const context = {
    github_error: {error:'github_rate_limited',retry_at:1600},
    selected_request: selected, selected_core:null, selected_error:'', selected_result:{},
    trafira_stopped_for_sing_box_change:false,
    updates_log:()=>{}, restart_trafira_after_failed_sing_box_change:()=>{},
    cleanup_action:()=>{}, exit:()=>{throw Error('stopped');},
    updates_response:(_ok,_component,_action,message)=>{result={...context.selected_result,message};},
  };
  vm.createContext(context); vm.runInContext(body, context);
  assert.throws(()=>context.action_fail('sing_box','install','generic preflight failed'),/stopped/);
  assert.strictEqual(result.error,'github_rate_limited','selected-version error must not overwrite cooldown');
  assert.strictEqual(result.retry_at,1600);
  assert(result.message.includes('GitHub request limit'));
}
console.log('component API failure response checks passed');
NODE
