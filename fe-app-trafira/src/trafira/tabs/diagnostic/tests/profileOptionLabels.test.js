import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import process from 'node:process';
import { afterEach, expect, it, vi } from 'vitest';
import { profileOptionLabels } from '../profileOptionLabels';

function russianMessages() {
  const messages = {};
  let key = '',
    value = '',
    field = '';
  const save = () => {
    if (key) messages[key] = value;
  };
  for (const line of readFileSync(
    '../luci-app-trafira/po/ru/trafira.po',
    'utf8',
  ).split(/\r?\n/)) {
    if (line.startsWith('msgid ')) {
      save();
      key = JSON.parse(line.slice(6));
      value = '';
      field = 'key';
    } else if (line.startsWith('msgstr ')) {
      value = JSON.parse(line.slice(7));
      field = 'value';
    } else if (line.startsWith('"')) {
      if (field === 'key') key += JSON.parse(line);
      else if (field === 'value') value += JSON.parse(line);
    }
  }
  save();
  return messages;
}
afterEach(() => vi.unstubAllGlobals());
it('keeps profile captions synchronized with native LuCI option definitions', () => {
  expect(() =>
    execFileSync(process.execPath, [
      'scripts/generate-profile-labels.mjs',
      '--check',
    ]),
  ).not.toThrow();
});
it('has a Russian translation for every known profile option caption', () => {
  const ru = russianMessages(),
    used = [];
  vi.stubGlobal('_', (label) => {
    used.push(label);
    return ru[label] || label;
  });
  const labels = profileOptionLabels();
  expect(labels.settings.gaming_presets_enabled).toBe(
    'Включить игровые пресеты',
  );
  expect(labels.settings.enable_yacd_wan_access).toBe(
    'Разрешить доступ к YACD из WAN',
  );
  expect(labels.options.failure_policy).toBe('Поведение при отказе VPN');
  expect(labels.options.community_lists).toBe('Встроенные наборы правил');
  for (const label of used)
    expect(ru[label], `Missing Russian caption: ${label}`).toBeTruthy();
});
