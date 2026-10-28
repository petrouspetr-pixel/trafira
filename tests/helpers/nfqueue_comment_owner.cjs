// Local fallback executes the production overlap functions with only ucode's
// array iteration syntax adapted. CI runs the shell suite with real ucode.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'trafira/files/usr/lib/providers/nfqueue/check.uc'), 'utf8');
const functions = source.slice(source.indexOf('function cleaned_queue_token'), source.indexOf('function rewrite_legacy_runtime_path'))
  .replace(/for \(let (\w+) in ([^\n]+)\) \{/g, 'for (let $1 of $2) {');
let input = '';
const context = vm.createContext({
  as_string: v => v == null ? '' : String(v),
  read_stdin: () => input,
  replace: (v, a, b) => v.replace(a, b),
  split: (v, s) => v.split(s),
  match: (v, p) => v.match(p),
  trim: v => v.trim(),
  substr: (v, start, count) => count == null ? v.slice(start) : v.slice(start, start + count),
  index: (v, s) => v.indexOf(s),
  int: Number,
  length: v => v.length,
  push: (v, item) => v.push(item),
});
vm.runInContext(functions, context);
let count = 0;
const shell = fs.readFileSync(path.join(root, 'tests/nfqueue_comment_owner.sh'), 'utf8');
for (const line of shell.split('\n')) {
  const fixture = line.match(/^check_rule ([01]) '([^']*)' '(.*)'$/);
  if (!fixture) continue;
  input = `table inet fw4 {\n chain incoming {\n  ${fixture[3]}\n }\n}\n`;
  const actual = context.nft_queue_overlap('TrafiraTable', 4300, 4555) ? 0 : 1;
  if (actual !== Number(fixture[1])) {
    console.error(`FAIL: ${fixture[2]}: expected exit ${fixture[1]}, got ${actual}`);
    process.exit(1);
  }
  count++;
}
if (count < 21) throw Error('Missing shell regression fixtures');
for (const [description, fixture, expected] of [
  ['marker is per rule', 'table inet fw4 {\n chain c {\n queue num 4300 comment "trafira-ignore"\n queue num 4301\n }\n}\n', true],
  ['own table does not exempt another table', 'table inet TrafiraTable {\n chain c {\n queue num 4300\n }\n}\ntable inet fw4 {\n chain c {\n queue num 4301\n }\n}\n', true],
  ['own table remains exempt', 'table inet TrafiraTable {\n chain c {\n queue num 4300\n }\n}\n', false],
]) {
  input = fixture;
  if (context.nft_queue_overlap('TrafiraTable', 4300, 4555) !== expected)
    throw Error(description);
}
console.log(`NFQUEUE production-function fallback checks passed (${count} rule cases, 3 ruleset cases; not a ucode syntax check)`);
