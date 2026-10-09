#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-trafira/htdocs/luci-static/resources/view/trafira/section.js" <<'NODE'
const assert = require('assert');
const source = require('fs').readFileSync(process.argv[2], 'utf8');
const snippet = source.slice(source.indexOf('function addSubscriptionPreviewOption('), source.indexOf('function addDashboardServerFilterOptions('));
String.prototype.format = function (...args) { let i=0; return this.replace(/%s/g, () => args[i++]); };
const values = { dashboard_filter_mode: 'include', dashboard_include_outbounds: ['<script>node</script>'], dashboard_include_proxy_parameters: '1', dashboard_include_protocols: ['vless'] };
const calls = [];
let reply = { code: 0, stdout: JSON.stringify({status:'ok',counts:{total:1,included:1,excluded:0},nodes:[{name:'<script>node</script>',status:'included',reason:'included'}],warnings:[]}) };
const fs = { exec: async (...args) => { calls.push(args); return reply; } };
const form = { DummyValue: {} };
const dom = { content: (node, children) => { node.children = children; } };
const E = (tag, attrs, children) => ({tag,attrs,children,appendChild(child) { if (!this.children) this.children=[]; this.children.push(child); }});
const _ = s => s;
const normalizeOptionValues = v => Array.isArray(v) ? v : v ? [v] : [];
const optionMapValue = () => '';
let option;
const optionSection = {option: () => option = {depends() {},map:{lookupOption:key=>[{formvalue:()=>values[key]}]}}};
eval(snippet);
addSubscriptionPreviewOption(optionSection);
const view = option.renderWidget('demo');
const [button,result] = view.children;
(async () => {
  await button.attrs.click();
  assert.equal(button.disabled,false);
  const request = JSON.parse(calls[0][1][1]);
  assert.equal(calls[0][0],'/usr/bin/trafira');
  assert.equal(calls[0][1][0],'subscription_preview');
  assert.equal(request.filter_mode,'include');
  assert.deepEqual(request.include.outbounds,['<script>node</script>']);
  assert.equal(request.include.proxy_parameters,true);
  assert.deepEqual(request.include.protocols,['vless']);
  assert.equal(result.children[2].children[0].children[0].children,'<script>node</script>','name must remain text passed to E, never markup');
  values.dashboard_include_groups=['group'];
  await button.attrs.click();
  assert.equal(calls.length,1,'group filters must not silently produce inaccurate preview');
  assert.match(result.children.children,/group filters/);
  values.dashboard_include_groups=[];
  reply={code:0,stdout:'{"status":"unavailable"}'};
  await button.attrs.click();
  assert.match(result.children.children,/no usable cached/);
  reply={code:1,stdout:'not json'};
  await button.attrs.click();
  assert.match(result.children.children,/Preview failed/);
  assert.equal(button.disabled,false);
  assert(!snippet.includes('innerHTML'));
  console.log('LuCI subscription preview checks passed');
})().catch(error => { console.error(error); process.exit(1); });
NODE
