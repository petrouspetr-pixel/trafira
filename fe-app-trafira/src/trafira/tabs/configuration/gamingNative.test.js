import { readFileSync } from 'node:fs';
import { expect, it, vi } from 'vitest';
import { GamingDraft, gamingUciChanges } from './gamingDraft';
import { gamingSwitchChanges } from './gamingSwitch';
const source = readFileSync(
  '../luci-app-trafira/htdocs/luci-static/resources/view/trafira/gaming.js',
  'utf8',
);
function setup() {
  let sections = [
    { '.name': 'settings', '.type': 'settings', gaming_presets_enabled: '1' },
    {
      '.name': 'vpn',
      '.type': 'section',
      action: 'connection',
      enabled: '1',
      password: 'keep-me',
    },
  ];
  const events = [];
  let failSave = false;
  const uci = {
    sections: () => sections,
    get: (_p, n, k) => sections.find((s) => s['.name'] === n)?.[k],
    set: (_p, n, k, v) => {
      events.push('set');
      sections.find((s) => s['.name'] === n)[k] = v;
    },
    unset: (_p, n, k) => {
      events.push('unset');
      delete sections.find((s) => s['.name'] === n)[k];
    },
    add: (_p, t, n) => {
      events.push('add');
      sections.push({ '.name': n, '.type': t });
      return n;
    },
    remove: (_p, n) => {
      events.push('remove');
      sections = sections.filter((s) => s['.name'] !== n);
    },
    move: (_p, n) => {
      if (!sections.find((s) => s && s['.name'] === n))
        throw Error('MOVE ' + n + ' ' + JSON.stringify(sections));
      events.push('move');
      const s = sections.find((s) => s['.name'] === n);
      sections = sections.filter((entry) => entry !== s);
      sections.push(s);
    },
  };
  const draft = new GamingDraft(async (input, ops) => {
    let result = JSON.parse(JSON.stringify(input));
    for (const op of ops) {
      const name = 'game_' + op.preset;
      if (op.action === 'remove')
        result = result.filter((s) => s.preset_owner !== op.owner);
      else {
        result = result.filter((s) => s.preset_owner !== name);
        result.splice(1, 0, {
          '.name': name,
          '.type': 'section',
          preset_owner: name,
          enabled: '1',
          action: 'connection',
        });
      }
    }
    return { success: true, config: result };
  });
  const flag = { option: 'gaming_presets_enabled', formvalue: () => '1' };
  const dummy = { depends: vi.fn() };
  const map = {
    save: async (callback) => {
      events.push('parse');
      uci.set('trafira', 'settings', 'ordinary_edit', 'preserved');
      if (callback) await callback();
      events.push('save');
      if (failSave) throw Error('offline');
    },
    reset: () => events.push('reset'),
  };
  const section = {
    map,
    option: (_type, name) => (name === 'gaming_presets_enabled' ? flag : dummy),
  };
  const api = {
    gamingUciChanges,
    gamingSwitchChanges,
    bindGamingDraft: (a) => draft.bind(a),
    saveGamingDraft: (cb) => draft.save(cb),
    flushGamingDraft: () => draft.flush(),
    resetGamingDraft: () => draft.reset(),
  };
  const module = new Function('baseclass', 'form', 'uci', 'main', '_', source)(
    { extend: (x) => x },
    {},
    uci,
    { TRAFIRA_UCI_PACKAGE: 'trafira', ConfigurationPanels: api },
    (x) => x,
  );
  module.createGamingContent(section);
  return {
    draft,
    map,
    events,
    sections: () => sections,
    fail: (value) => {
      failSave = value;
    },
  };
}
it('native Save parses ordinary fields, flushes all preset changes once, and preserves private options', async () => {
  const t = setup();
  await t.draft.stage({ action: 'upsert', preset: 'steam' });
  await t.draft.stage({ action: 'upsert', preset: 'epic' });
  expect(t.events).toEqual([]);
  await t.map.save();
  expect(t.events[0]).toBe('parse');
  expect(t.events.at(-1)).toBe('save');
  expect(t.events.filter((x) => x === 'save')).toHaveLength(1);
  expect(t.sections().map((s) => s['.name'])).toEqual([
    'settings',
    'game_epic',
    'game_steam',
    'vpn',
  ]);
  expect(t.sections().find((s) => s['.name'] === 'vpn').password).toBe(
    'keep-me',
  );
  expect(t.sections()[0].ordinary_edit).toBe('preserved');
  expect(t.draft.pending).toBe(0);
});
it('removal and Reset touch no UCI, and footer Apply activates the batch only once', async () => {
  const t = setup();
  await t.draft.stage({ action: 'upsert', preset: 'steam' });
  await t.map.save();
  t.events.length = 0;
  await t.draft.stage({ action: 'remove', owner: 'game_steam' });
  expect(t.events).toEqual([]);
  t.map.reset();
  expect(t.sections().some((s) => s.preset_owner)).toBe(true);
  expect(t.draft.pending).toBe(0);
  t.events.length = 0;
  await t.draft.stage({ action: 'remove', owner: 'game_steam' });
  const apply = vi.fn();
  await t.map.save();
  await apply();
  expect(apply).toHaveBeenCalledTimes(1);
  expect(t.sections().some((s) => s.preset_owner)).toBe(false);
  expect(t.events.filter((x) => x === 'save')).toHaveLength(1);
});

it('failed Save rolls local gaming edits back; Reset and the next Save cannot resurrect them', async () => {
  const t = setup();
  await t.draft.stage({ action: 'upsert', preset: 'steam' });
  t.fail(true);
  await expect(t.map.save()).rejects.toThrow('offline');
  expect(t.draft.pending).toBe(1);
  expect(t.sections().some((s) => s.preset_owner)).toBe(false);
  expect(t.sections()[0].ordinary_edit).toBe('preserved');
  t.map.reset();
  t.fail(false);
  await t.map.save();
  expect(t.sections().some((s) => s.preset_owner)).toBe(false);
  // A rejected deletion restores the saved rule as well.
  await t.draft.stage({ action: 'upsert', preset: 'steam' });
  await t.map.save();
  await t.draft.stage({ action: 'remove', owner: 'game_steam' });
  t.fail(true);
  await expect(t.map.save()).rejects.toThrow('offline');
  expect(t.sections().some((s) => s.preset_owner === 'game_steam')).toBe(true);
  t.fail(false);
  await t.map.save();
  expect(t.sections().some((s) => s.preset_owner)).toBe(false);
});
