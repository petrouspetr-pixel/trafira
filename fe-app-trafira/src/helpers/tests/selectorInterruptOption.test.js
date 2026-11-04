import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const source = fs.readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../../../luci-app-trafira/htdocs/luci-static/resources/view/trafira/section.js',
  ),
  'utf8',
);
function optionDefinition() {
  const block = source.match(
    / {2}o = section\.taboption\(\s*"settings",\s*form\.Flag,\s*"selector_interrupt_exist_connections",[\s\S]*?(?=\n {2}o = section\.taboption\()/,
  );
  expect(block, 'native section selector flag is missing').not.toBeNull();
  const dependencies = [];
  const section = {
    taboption: (tab, type, name, title, description) => ({
      tab,
      type,
      name,
      title,
      description,
      depends: (...args) => dependencies.push(args),
    }),
  };
  const Flag = {};
  const option = new Function(
    'section',
    'form',
    '_',
    `let o; ${block[0]}; return o;`,
  )(section, { Flag }, (value) => value);
  return { option, dependencies, Flag };
}
describe('section selector connection policy', () => {
  it('uses a native Flag with the previous default and keeps explicit zero', () => {
    const { option, Flag, dependencies } = optionDefinition();
    expect(option.type).toBe(Flag);
    expect(option.default).toBe('1');
    expect(option.rmempty).toBe(false);
    expect(option.modalonly).toBe(true);
    expect(dependencies).toEqual([['action', 'connection']]);
  });
  it('stages the value through the native form without an immediate service action', () => {
    const { option } = optionDefinition();
    for (const method of ['write', 'remove', 'onchange'])
      expect(option[method]).toBeUndefined();
    expect(option.description).toContain('URLTest');
    expect(option.description).toContain('Priority');
  });
});
