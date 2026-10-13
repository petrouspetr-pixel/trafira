import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { gzipSync } from 'node:zlib';
const require = createRequire(import.meta.url);
const esbuild = createRequire(require.resolve('tsup'))('esbuild');
const code = fs.readFileSync(
  '../luci-app-trafira/htdocs/luci-static/resources/view/trafira/main.js',
  'utf8',
);
const source = fs.readFileSync('src/main.ts', 'utf8');
const expected = [...source.matchAll(/export\s*\{([^}]+)\}/g)]
  .flatMap((m) =>
    m[1]
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  )
  .sort();
const exported = code.match(
  /return baseclass\.extend\(\{([^{}]+)\}\)\s*;?\s*$/,
);
assert(exported, 'LuCI bundle must return its public API');
assert.deepEqual(
  exported[1]
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .sort(),
  expected,
  'Public export names must survive compaction',
);
for (const name of ['baseclass', 'fs', 'uci', 'ui']) {
  assert(
    code.includes(`"require ${name}";`) || code.includes(`'require ${name}';`),
    `LuCI dependency directive missing: ${name}`,
  );
}
new Function(code);
const baseline = esbuild.buildSync({
  entryPoints: ['src/main.ts'],
  bundle: true,
  write: false,
  format: 'esm',
  target: 'es2020',
  legalComments: 'none',
}).outputFiles[0].text;
assert(
  Buffer.byteLength(code) < Buffer.byteLength(baseline) * 0.85,
  'Bundle must retain a meaningful size reduction',
);
assert(
  gzipSync(code).length < gzipSync(baseline).length,
  'Compaction must also reduce compressed size',
);
console.log(
  `LuCI bundle contract passed: ${expected.length} public exports, ${Buffer.byteLength(code)} bytes`,
);
