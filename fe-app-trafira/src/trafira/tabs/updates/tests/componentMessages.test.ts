import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import catalog from '../../../../../locales/trafira.ru.po?raw';
import {
  componentSuccessMessage,
  componentErrorMessage,
} from '../componentMessages';

beforeEach(() => {
  const translations: Record<string, string> = {
    '%s has been installed': '%s установлен',
    '%s has been removed': '%s удалён',
    'Failed to install LuCI app package':
      'Не удалось установить пакет приложения LuCI',
    'Failed to execute component action':
      'Не удалось выполнить действие с компонентом',
  };
  vi.stubGlobal('_', (text: string) => translations[text] || text);
});
afterEach(() => vi.unstubAllGlobals());

it.each(['trafira', 'sing_box', 'zapret', 'zapret2', 'byedpi'] as const)(
  'localizes successful installation of %s using structured fields',
  (component) => {
    const message = componentSuccessMessage({ component, action: 'install' });
    expect(message).toContain('установлен');
    expect(message).not.toContain('has been');
  },
);
it('localizes variant installation and removal', () => {
  expect(
    componentSuccessMessage({ component: 'sing_box', action: 'install_tiny' }),
  ).toBe('sing-box-tiny установлен');
  expect(
    componentSuccessMessage({ component: 'zapret2', action: 'remove' }),
  ).toBe('Zapret2 удалён');
});
it('translates a package error while preserving its diagnostic suffix', () => {
  expect(
    componentErrorMessage(
      'Failed to install LuCI app package: insufficient space',
    ),
  ).toBe('Не удалось установить пакет приложения LuCI: insufficient space');
});
it('keeps unknown diagnostic details with a localized introduction', () => {
  expect(componentErrorMessage('apk: conflict with installed package')).toBe(
    'Не удалось выполнить действие с компонентом: apk: conflict with installed package',
  );
});

it('uses the shipped Russian catalog for component notifications', () => {
  const translations = Object.fromEntries(
    [...catalog.matchAll(/msgid "([^"\n]+)"\nmsgstr "([^"\n]+)"/g)].map(
      (match) => [match[1], match[2]],
    ),
  );
  vi.stubGlobal('_', (text: string) => {
    expect(
      translations[text],
      `Missing Russian translation: ${text}`,
    ).toBeTruthy();
    return translations[text];
  });
  expect(
    componentSuccessMessage({ component: 'trafira', action: 'install' }),
  ).toBe('Trafira установлен');
  expect(componentErrorMessage('Failed to install LuCI app package')).toBe(
    'Не удалось установить пакет приложения LuCI',
  );
  expect(componentErrorMessage(translations['Failed to execute'])).toBe(
    translations['Failed to execute'],
  );
});
