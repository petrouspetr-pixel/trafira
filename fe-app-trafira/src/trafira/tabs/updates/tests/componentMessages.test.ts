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

it('translates configuration contention without an English diagnostic suffix', () => {
  vi.stubGlobal('_', (text: string) =>
    text === 'Another configuration operation is already running.'
      ? 'Уже выполняется другая операция с конфигурацией.'
      : text,
  );
  expect(
    componentErrorMessage('Another configuration operation is already running'),
  ).toBe('Уже выполняется другая операция с конфигурацией.');
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

it('translates RAM update preparation errors from the shipped catalog', () => {
  const translations = Object.fromEntries(
    [...catalog.matchAll(/msgid "([^"\n]+)"\nmsgstr "([^"\n]+)"/g)].map((m) => [
      m[1],
      m[2],
    ]),
  );
  vi.stubGlobal('_', (text: string) => translations[text] || text);
  expect(
    componentErrorMessage(
      'Cannot prepare verified Extended rollback in RAM; running service was not changed',
    ),
  ).toBe(
    'Не удалось проверить обновление Extended в RAM. Работающая служба не изменена.',
  );
  expect(
    componentErrorMessage(
      'Cannot preserve verified Extended rollback in RAM; running service was not changed',
    ),
  ).toBe(
    'Не хватает ресурсов для безопасного отката Extended в RAM. Работающая служба не изменена.',
  );
  expect(
    componentErrorMessage(
      'Previous sing-box process did not stop; existing package files were not removed',
    ),
  ).toBe(
    'Предыдущий процесс sing-box не остановился. Файлы установленного пакета сохранены.',
  );
  expect(
    componentErrorMessage('Cannot finish already installed core selection'),
  ).toBe('Не удалось завершить выбор уже установленной версии sing-box.');
});
