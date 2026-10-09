# Configuration Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Сохранение, сравнение, импорт/экспорт и применение восьми профилей Trafira с восстановлением.
**Architecture:** Ограниченное приватное хранилище отдельно от асинхронного применяющего worker. Изменения конфигурации и пакетов согласуются общей блокировкой, восстановление работает независимо от открытой страницы.
**Tech Stack:** ucode fs/UCI, procd, LuCI TypeScript, shell integration fixtures.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 2.

## Global Constraints

Наследует основной план. Только `/etc/config/trafira`; восемь пользовательских профилей, до 1 МиБ каждый, до 8 МиБ всего. Каталог 0700, файлы 0600. Сертификаты, сеть, firewall и пакеты в архив не входят. Аварийный предыдущий профиль хранится отдельно и не вытесняется лимитом восьми.

## Review Focus

- Сбой питания/worker после замены UCI, но до проверки службы.
- Пользователь редактирует настройки между просмотром различий и применением.
- Импорт содержит путь `../`, симлинк или неизвестную версию схемы.
- Отсутствуют ключевой файл, сетевой интерфейс или установленный компонент.
- Параллельны обновление пакета, reload и применение профиля.

### Task 1: Формат, хранение и маскированное сравнение

**Files:** Create `LIB/config/profiles.uc`, `LIB/config/profile_format.uc`, `tests/config_profiles.sh`; modify `LIB/config/validator.uc` для проверки изолированного кандидата без сохранения глобальной UCI.

**Interfaces:** `profile_format.validate(document)` → `{valid,errors}`; документ `{schema:1,name,created_at,config}` с config как структурированным экспортом секций Trafira. `profiles.list/create/rename/remove/export/import/preview` принимают валидированный запрос, возвращают `{success,error?,...}`. ID — сгенерированная безопасная строка, имя никогда не путь. `preview(id,current_digest)` возвращает маскированные изменения, отсутствующие зависимости и digest исходной UCI.

- [ ] В `tests/config_profiles.sh` задать проверки формата и границ:

```ucode
let p = require("config.profile_format");
assert(!p.validate({schema:99,name:"A",config:[]}).valid);
assert(!p.validate({schema:1,name:"A",config:{network:[]}}).valid);
assert(!p.validate({schema:1,name:"",config:[]}).valid);
```

- [ ] Запустить тест до реализации, зафиксировать красный результат. Реализовать нормализацию типизированных секций/option/list без исполнения UCI-текста как shell. Имя 1–64 символа, ID `[a-z0-9-]{1,64}`, типы и поля сверяются с актуальной схемой Trafira; неподдержанные настройки возвращают явную ошибку.
- [ ] Добавить записи temp → flush/close → rename на том же разделе, запрет симлинков и чужих файлов, расчёт квоты до записи. Импорт JSON проверяет размер до разбора. Тесты: девятый профиль, 1 МиБ+1, сбой rename/write, нехватка места, скрытые секреты в diff и отсутствие сети в экспорте.
- [ ] Проверить внешние пути и интерфейсы существующим валидатором в режиме кандидата, не раскрывая содержимое ключей. Прогнать тесты до PASS; commit `feat: store bounded Trafira configuration profiles`.

### Task 2: Транзакционное применение и UI

**Files:** Create `LIB/service/config_transaction.uc`, `LIB/service/operation_lock.uc`, `LIB/config/profile_cli.uc`, `tests/config_profile_apply.sh`, `FE/tabs/diagnostic/profilePanel.ts`, `FE/tabs/diagnostic/renderProfiles.ts`, `FE/tabs/diagnostic/tests/profilePanel.test.ts`; modify `LIB/service/lifecycle.uc`, `LIB/components/action.uc`, `LIB/components/updates.uc`, CLI, diagnostic render/controller и RPC ACL.

**Interfaces:**
- `operation_lock.acquire(operation)` → fs handle либо null; `release(handle)` закрывает handle. Один стабильный inode `/var/run/trafira/operation.lock`, exclusive nonblocking kernel lock; отсутствие возможности lock = отказ изменяющей операции.
- `config_transaction.apply(candidate_path, expected_digest, reason)` → `{success,restored,rollback_error?,job_id}`; вызывается worker под общей блокировкой. Внутренние шаги lifecycle отделить от внешних точек входа, чтобы вложенный restart не захватывал ту же блокировку заново.
- CLI `profile_action JSON` поддерживает `list|create|rename|remove|preview|apply|restore|import|export|status`. Долгие действия отвечают job_id. Импорт до 1 МиБ идёт через приватный staged файл фиксированного каталога, не через argv; имена staged объектов валидируются. Экспорт — явное действие авторизованного администратора, содержимое не входит в status/log.

- [ ] В тесте запустить два worker с общим lock: второй получает busy, не изменив UCI. Инъекции отказа по стадиям записать как исполняемую таблицу:

```json
[
 {"failure":"validate","expected":"original-unchanged"},
 {"failure":"candidate-check","expected":"original-unchanged"},
 {"failure":"restart","expected":"original-restored"},
 {"failure":"worker-death-after-replace","expected":"recover-on-next-start"},
 {"failure":"restore-start","expected":"rollback-failed-explicitly"},
 {"failure":"digest-changed","expected":"conflict-without-replace"}
]
```

- [ ] Сохранить исходную UCI, её digest, состояние enabled/running и журнал стадий до замены. Порядок: operation lock → существующий reload lock → subscription lock. Никакой компонент не ждёт operation lock, уже удерживая нижний lock. Все внешние start/reload/update входы используют этот порядок; внутренний restart вызывается напрямую под владельцем операции, без пользовательского флага «обойти lock».
- [ ] Генерацию кандидата выполнять с отдельным UCI cursor и отдельными cache/ruleset путями. Проверить кандидат установленным ядром. Перед commit повторно сравнить expected_digest; при изменении вернуть conflict. Применить и проверить состояние службы; если она была остановлена, профиль не включает её автоматически. При незавершённом журнале следующий startup сначала восстанавливает исходник. Ошибка восстановления не скрывается сообщением успеха.
- [ ] UI: список, создать/переименовать/удалить, masked diff, apply/restore и явный export с предупреждением о секретах. Импорт использует ограниченный upload; ACL не даёт чтение всего каталога профилей. При закрытии страницы worker продолжает; повторное открытие читает job status. Проверить Vitest: повторный click, stale response, conflict, restore error, секреты отсутствуют в DOM предпросмотра.
- [ ] Запустить `bash tests/config_profiles.sh`, `bash tests/config_profile_apply.sh`, затем Integration Gate. Commit `feat: apply configuration profiles with recovery`.
