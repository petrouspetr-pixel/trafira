import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { gzipSync } from 'node:zlib';
import { parse } from '@babel/parser';
import vm from 'node:vm';
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
const ast = parse(code, {
  sourceType: 'script',
  allowReturnOutsideFunction: true,
});
const exported = ast.program.body.at(-1);
assert(
  exported?.type === 'ReturnStatement' &&
    exported.argument?.callee?.object?.name === 'baseclass',
  'LuCI bundle must return its public API',
);
assert.deepEqual(
  exported.argument.arguments[0].properties
    .map((property) => property.key.name)
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
// Execute the delivered module too: aliases must point to the actual objects.
const api = vm.runInNewContext(
  `(function(){${code}\n})()`,
  {
    baseclass: { extend: (object) => object },
    fs: {},
    uci: {},
    ui: {},
    _: (text) => text,
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    document: {
      body: {},
      querySelectorAll: () => [],
      querySelector: () => null,
      addEventListener() {},
    },
    window: { addEventListener() {} },
    console,
    URL,
    structuredClone,
    setTimeout: () => 0,
    clearTimeout() {},
  },
  { timeout: 5000 },
);
assert.deepEqual(Object.keys(api).sort(), expected);
assert.equal(api.validateIP('192.168.10.234').valid, true);
assert.equal(api.validateIP('::1').valid, true);
assert.equal(api.validateIP('999.999.999.999').valid, false);
assert.equal(typeof api.ConfigurationPanels.init, 'function');
assert.equal(typeof api.DashboardTab.render, 'function');
assert.equal(typeof api.TrafiraShellMethods, 'object');
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
