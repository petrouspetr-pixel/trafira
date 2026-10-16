import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import process from 'node:process';
import { parse } from '@babel/parser';
import {
  toLuciModule,
  compactLuciSource,
} from '../../../scripts/luci-compaction.mjs';

describe('release JavaScript compaction', () => {
  it('compacts all staged modules without changing source files or dependencies', () => {
    const directory =
      '../luci-app-trafira/htdocs/luci-static/resources/view/trafira';
    const staged = fs.mkdtempSync(path.join(os.tmpdir(), 'trafira-luci-size-'));
    try {
      let before = 0,
        after = 0;
      for (const name of fs
        .readdirSync(directory)
        .filter((file) => file.endsWith('.js')))
        fs.copyFileSync(path.join(directory, name), path.join(staged, name));
      execFileSync(process.execPath, [
        'scripts/compact-luci-package.mjs',
        staged,
      ]);
      for (const name of fs.readdirSync(staged)) {
        const source = fs.readFileSync(path.join(directory, name), 'utf8');
        const compact = fs.readFileSync(path.join(staged, name), 'utf8');
        if (name === 'main.js') {
          expect(compact).toBe(source);
          continue;
        }
        const ast = (code) =>
          parse(code, {
            sourceType: 'script',
            allowReturnOutsideFunction: true,
          });
        const directives = (code) =>
          ast(code).program.directives.map((item) => item.value.value);
        expect(directives(compact)).toEqual(directives(source));
        expect(() => new Function(compact)).not.toThrow();
        before += Buffer.byteLength(source);
        after += Buffer.byteLength(compact);
      }
      expect(after).toBeLessThan(before * 0.75);
    } finally {
      fs.rmSync(staged, { recursive: true });
    }
  });
  it('keeps public LuCI names when esbuild shortens internal identifiers', () => {
    const source =
      '"require baseclass"; const a = (x) => x + 1; export { a as validateIP };';
    const code = toLuciModule(source);
    const api = new Function('baseclass', code)({ extend: (object) => object });
    expect(Object.keys(api)).toEqual(['validateIP']);
    expect(api.validateIP(4)).toBe(5);
  });
  it('preserves dependency directives, translation strings and module behavior', () => {
    const source = `"use strict"; "require baseclass"; "require form as nativeForm";
      // This comment is not needed on the router.
      const caption = _("Enable gaming presets");
      return baseclass.extend({ label: caption, getValue: function (deviceAddress) { return deviceAddress + nativeForm.value; } });`;
    const code = compactLuciSource(source);
    expect(code.length).toBeLessThan(source.length);
    expect(code).toContain('"require form as nativeForm";');
    const api = new Function('baseclass', 'nativeForm', '_', code)(
      { extend: (object) => object },
      { value: '!' },
      (text) => text,
    );
    expect(api.label).toBe('Enable gaming presets');
    expect(api.getValue('router')).toBe('router!');
  });
  it('does not silently accept an unexpected ESM export format', () => {
    expect(() => toLuciModule('export default 1')).toThrow();
  });
});
