# Sing-box Version Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Выбирать, закреплять и понижать совместимые доступные версии sing-box с офлайн-откатом.
**Architecture:** Каталог версий выдаёт проверенные идентификаторы кандидатов; существующий installer получает выбранного кандидата вместо безусловного latest. Подмена URL клиентом исключена.
**Tech Stack:** ucode, APK/IPK, GitHub release API, component workers, TypeScript.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 3.

## Global Constraints

Наследует основной план. Использует `service.operation_lock` этапа профилей. Закрепление относится к Trafira, не обещает запрета ручного обновления через apk/opkg. Прямое подключение к GitHub не заменяет заданный пользователем транспорт загрузки.

## Review Focus

- Правильная версия при неправильной архитектуре или варианте пакета.
- Версия удалена из источника после открытия списка.
- Нельзя восстановить предыдущий пакет без сети.
- Более старое ядро не поддерживает текущую конфигурацию.
- Новая версия не должна сохраняться как выбранная после неудачной установки.

### Task 1: Каталог и закрепление

**Files:** Create `LIB/components/core_versions.uc`, `tests/core_versions.sh`; modify `LIB/components/action.uc`, `LIB/components/updater.uc`, `LIB/components/updates.uc`, `LIB/config/validator.uc`, default UCI config при необходимости.

**Interfaces:** `core_versions.catalog(releases,environment)` → `{entries,unavailable_reason}`; entry = `{id,version,variant,architecture,package_type,available,reason,release_url}`. environment = `{variant,architecture,package_type}`. `core_versions.resolve(id,environment)` возвращает серверный объект кандидата, не принимает URL от UI. Настройки `sing_box_pinned_version` и `sing_box_pinned_variant`; пустые = latest текущего варианта.

- [ ] Написать fixture-тест, используя только вымышленные версии и адреса:

```json
[
 {"tag":"v1.14.2","arch":"aarch64","kind":"apk","stable":true,"expect":"available"},
 {"tag":"v1.14.2","arch":"x86_64","kind":"apk","stable":true,"expect":"wrong-architecture"},
 {"tag":"v1.15.0-beta.1","arch":"aarch64","kind":"apk","stable":false,"expect":"excluded"},
 {"tag":"v1.14.1","arch":"aarch64","kind":"ipk","stable":true,"expect":"wrong-package-type"}
]
```

- [ ] Запустить `bash tests/core_versions.sh` до добавления модуля. Реализовать разрешение метаданных из источников, уже используемых установщиком. Для обычного пакета перечислять реально доступные версии репозитория пакетов, для extended — стабильные release assets соответствующего проекта; не выдавать произвольный upstream binary за APK/IPK.
- [ ] Кэш метаданных 15 минут, до 100 кандидатов и 2 МиБ ответа. UI видит время кэша, ошибку сети и возможность обновить; перед установкой кандидат разрешается заново. Отображение `available` означает найденный артефакт, не успешную runtime-проверку.
- [ ] Проверить pin: latest новее, но обычное обновление удерживает pin; отсутствующая pinned версия не заменяется другой; удаление pin возвращает штатное поведение. Отдельная команда смены варианта не смешивается с выбором версии. Commit `feat: list and pin available sing-box versions`.

### Task 2: Проверка кандидата, установка и откат

**Files:** Modify `LIB/components/action.uc` (resolve/install/rollback functions), `LIB/components/updates.uc` (async worker), CLI, `FE/methods/shell/index.ts`, `FE/tabs/updates/render.ts`, `FE/tabs/updates/initController.ts`; create `tests/core_version_install.sh`, `FE/tabs/updates/coreVersionPicker.ts`, `FE/tabs/updates/tests/coreVersionPicker.test.ts`.

**Interfaces:** `component_versions sing-box` → catalog; `component_version_action JSON` с `{action:"install"|"unpin",candidate_id?,pin:boolean,expected_current_version}` → `{success,job_id?,error?}`. Не менять контракт старых `component_action*`; дополнительный запрос worker сохраняет в приватном job file, а не дописывает непроверенные shell-аргументы.

- [ ] Тестировать установку с поддельными пакетным менеджером/бинарниками/транспортом. Проверки: candidate не найден, checksum mismatch, archive traversal, нет места, нет rollback-пакета, candidate check падает, restart падает, offline restore проходит, исходная версия успела измениться.
- [ ] Под operation lock сохранить существующий пригодный пакет/бинарник и библиотеки через текущие rollback-функции. Распаковать кандидата в приватный tmp, проверить метаданные и доступную опубликованную контрольную сумму. Сгенерировать кандидат конфигурации с возможностями выбранного ядра в изоляции, выполнить его `check` со staged библиотеками. Отсутствие корректного способа проверить данный вариант — явная недоступность, не пропуск проверки.
- [ ] Заменить пакет только после preflight; подтвердить фактическую версию и состояние службы. Pin и variant metadata записать последними. На любой ошибке восстановить пакет, конфигурацию и старый pin без сети. Старый и новый rollback используют одинаковый механизм, без второго конкурирующего установщика.
- [ ] UI state machine:

```ts
export type VersionStage = 'idle' | 'loading' | 'selected' | 'installing' | 'done' | 'failed';
export interface VersionSelection {
  candidate_id: string;
  expected_current_version: string;
  pin: boolean;
}
// install(selection) возвращает job_id; результат подтверждается component status.
// Смена radio/select во время installing заблокирована; failed сохраняет причину отката.
```

- [ ] Vitest: загрузка stale catalog, недоступная сборка, downgrade, повторный click, worker error и успешно восстановленная предыдущая версия. Запустить targeted tests и Integration Gate; commit `feat: install selected sing-box versions with rollback`.
