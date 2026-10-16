import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { compactLuciSource } from './luci-compaction.mjs';

const root = process.argv[2];
assert(
  root && fs.statSync(root).isDirectory(),
  'Pass the staged LuCI module directory',
);
let before = 0,
  after = 0;
for (const name of fs.readdirSync(root).sort()) {
  if (!name.endsWith('.js') || name === 'main.js') continue;
  const file = path.join(root, name);
  const source = fs.readFileSync(file, 'utf8');
  const code = compactLuciSource(source);
  const directives = (text) =>
    [...text.matchAll(/["'](require [^"']+)["'];/g)].map((m) => m[1]);
  assert.deepEqual(
    directives(code),
    directives(source),
    `LuCI dependencies changed in ${name}`,
  );
  before += Buffer.byteLength(source);
  after += Buffer.byteLength(code);
  fs.writeFileSync(file, code);
}
console.log(
  `Staged LuCI scripts: ${before} -> ${after} bytes (sources unchanged)`,
);
