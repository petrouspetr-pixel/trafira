import { expect, it } from 'vitest';
import { gamingSwitchChanges } from './gamingSwitch';
const preset = {
  '.name': 'game',
  preset_owner: 'steam',
  action: 'bypass',
  enabled: '1',
  preset_original_digest: '{ "action": "bypass", "enabled": "1" }',
};
function stage(sections: Record<string, unknown>[], enabled: boolean) {
  const result = structuredClone(sections);
  for (const e of gamingSwitchChanges(result, enabled)) {
    const section = result.find((s) => s['.name'] === e.section)!;
    if (e.value === undefined) delete section[e.option];
    else section[e.option] = e.value;
  }
  return result;
}
it('stages reversible preset-only edits without mutating the input', () => {
  const sections = [preset, { '.name': 'ordinary', enabled: '1' }];
  const off = stage(sections, false);
  expect(sections[0].enabled).toBe('1');
  expect(off[0]).toMatchObject({
    enabled: '0',
    preset_resume_enabled: '1',
    preset_original_digest: '{ "action": "bypass", "enabled": "0" }',
  });
  expect(off[1]).toEqual(sections[1]);
  expect(stage(stage(off, false), true)).toEqual(sections);
});
it('preserves manually disabled rules and edited warnings', () => {
  const edited = { ...preset, enabled: '0', label: 'Manual' };
  const on = stage(stage([edited], false), true);
  expect(on).toEqual([edited]);
});
it('restores rules disabled by the preceding version', () => {
  const legacy = {
    ...preset,
    enabled: '0',
    preset_resume_enabled: '1',
    preset_original_digest: '{ "action": "bypass", "enabled": "0" }',
  };
  expect(stage([legacy], true)).toEqual([preset]);
});
