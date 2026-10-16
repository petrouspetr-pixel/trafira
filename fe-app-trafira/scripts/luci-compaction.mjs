import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const esbuild = createRequire(require.resolve('tsup'))('esbuild');

// LuCI consumes object keys, not ESM bindings. Only private identifiers may shrink.
export function toLuciModule(source) {
  const match = source.match(/\bexport\s*\{([^{}]+)\}\s*;?\s*$/);
  assert(match, 'Expected a final named ESM export list');
  const properties = match[1]
    .split(',')
    .filter((item) => item.trim())
    .map((item) => {
      const binding = item.trim().match(/^([\w$]+)(?:\s+as\s+([\w$]+))?$/);
      assert(binding, `Unexpected export binding: ${item}`);
      return `${binding[2] || binding[1]}:${binding[1]}`;
    });
  return (
    source.slice(0, match.index) +
    `return baseclass.extend({${properties.join(',')}});\n`
  );
}

export function compactLuciSource(source) {
  const code = esbuild.transformSync(source, {
    target: 'es2020',
    minify: true,
    legalComments: 'none',
  }).code;
  new Function(code);
  return code;
}
