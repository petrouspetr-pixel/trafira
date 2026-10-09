# VPN Failure Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить явное поведение секции при отказе VPN, задержку переключения и понятный статус.
**Architecture:** Чистая машина состояний расширяет существующий priority worker. Генератор применяет выбранный результат к правилам секции; lifecycle выполняет изменения под общей блокировкой и сохраняет безопасное состояние при сбое.
**Tech Stack:** ucode, Clash API, sing-box route actions, nftables, LuCI JS/TypeScript.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 4.

## Global Constraints

Наследует основной план. Старые секции = `legacy`; новый direct разрешён только настройкой `direct`. Резерв при собственном отказе блокирует соединения. Не обещать kill switch после остановки Trafira. Не создавать устаревший block-outbound.

## Review Focus

- Ошибка Clash API или самого probe не является подтверждённой недоступностью узла.
- Сбой применения reject не должен открыть путь через final/direct.
- Резерв ссылается на исходную секцию через цепочку зависимостей.
- Ручной выбор и автоматический контроллер одновременно меняют группу.
- Старые соединения продолжают использовать предыдущий выход.

## Task 1: Модель состояния и расширение priority worker

**Files:** Create `LIB/singbox/failure_policy.uc`, `tests/failure_policy.sh`; modify `LIB/singbox/priority.uc`, `LIB/config/validator.uc`, `LIB/config/connections.uc`, `LUCI/section.js`.

**Interfaces:** `failure_policy.step(state,sample,now,policy)` → `{state,transition}`. sample = `{primary:"up"|"down"|"unknown",reserve:"up"|"down"|"unknown"}`; transition = null либо `{from,to,reason}`. state содержит mode, fail_count, success_count, last_transition, observed_at. policy = `{mode,reserve_section,failures:3,recoveries:2,hold_seconds:30}`. UCI: `failure_policy=legacy|block|reserve|direct`, `failure_reserve_section`, `failure_threshold`, `recovery_threshold`, `failure_hold_seconds`.

- [ ] Создать тест последовательности:

```ucode
let p = require("singbox.failure_policy");
let policy = {mode:"direct",failures:3,recoveries:2,hold_seconds:30};
let state = {mode:"primary",fail_count:0,success_count:0,last_transition:0,observed_at:0};
state = p.step(state,{primary:"down",reserve:"unknown"},40,policy).state;
state = p.step(state,{primary:"down",reserve:"unknown"},45,policy).state;
assert(state.mode == "primary");
let third = p.step(state,{primary:"down",reserve:"unknown"},50,policy);
assert(third.transition.to == "direct");
let unknown = p.step(state,{primary:"unknown",reserve:"unknown"},50,policy);
assert(unknown.transition == null);
```

- [ ] Запустить `bash tests/failure_policy.sh` до реализации. Реализовать чистую функцию с монотонным временем, сбросом последовательных счётчиков при unknown и без изменений старого алгоритма для legacy. Порог отказа/восстановления 1–10, hold 30–600 секунд. Начальное состояние новых строгих политик до первой успешной проверки — blocked; direct не включается до подтверждённого порога отказов.
- [ ] Добавить тесты recovery, удержания, изменения времени, restart со старым observed_at, отказа резерва, исчезновения узла из подписки и отрицательных/слишком больших значений. Валидатор отклоняет отсутствующий reserve, disabled секцию, self reference и любой цикл, включая detour/cascade.
- [ ] Встроить одну машину состояния на секцию в priority worker: существующие проверки доступности переиспользуются; владение selector не дублируется. Для управляемой секции ручной выбор основного узла обновляет primary target и сбрасывает счётчики, не отключая политику. Отчёт `{section,policy,state,reason,changed_at,monitor_error}` без адресов/секретов. Commit `feat: model explicit VPN failure policies`.

## Task 2: Безопасное применение, дашборд и интеграционный стенд

**Files:** Modify `LIB/singbox/generator.uc`, `LIB/service/lifecycle.uc`, `LIB/nft/apply.uc`, `LIB/service/state.uc`, `FE/tabs/dashboard/render.ts`, `FE/tabs/dashboard/partials/renderSections.ts`, CLI; create `LIB/service/failure_policy_apply.uc`, `tests/failure_policy_apply.sh`, `tests/failure_policy_network.sh`, `FE/tabs/dashboard/helpers/failurePolicy.ts`, `FE/tabs/dashboard/helpers/tests/failurePolicy.test.ts`.

**Interfaces:** `failure_policy_apply.apply(section,expected_generation,target)` → `{success,applied_generation,error}` под `service.operation_lock`. target = `primary|reserve|direct|blocked`. Runtime state хранится в `/var/run/trafira/failure-policy.json`; генератор читает только состояние с совпадающим fingerprint конфигурации. CLI `failure_policy_status` возвращает отчёт задачи 1.

- [ ] В тестах сначала зафиксировать выбранную генерацию:

```json
[
 {"policy":"legacy","state":"down","expect":"unchanged"},
 {"policy":"block","state":"blocked","expect_action":"reject"},
 {"policy":"reserve","state":"reserve","expect_outbound":"reserve-out"},
 {"policy":"reserve","state":"blocked","expect_action":"reject"},
 {"policy":"direct","state":"direct","expect_outbound":"bypass-out"}
]
```

- [ ] Сохранить исходные matcher-условия и порядок секции; заменить только конечное действие. Блокировка действует и на полный маршрут устройства, и на mixed/server входы, привязанные к секции. DNS не должен незаметно использовать direct вопреки политике; bootstrap-транспорт отделён от пользовательских DNS-запросов.
- [ ] При необходимости reload сначала установить временный nft guard для уже перехватываемого Trafira трафика, затем проверить/применить конфигурацию, подтвердить runtime и убрать guard. Guard сохраняет системные исключения и не открывает direct при сбое. Старые соединения завершаются при переключении; UI прямо сообщает это. Не обещать атомарность двух разных подсистем: обеспечивать безопасный порядок и откат. При ошибке сохранять guard до восстановления пригодной конфигурации и явно сообщать degraded state.
- [ ] На Linux network namespace стенде создать direct-счётчик и управляемые primary/reserve endpoints; тестировать отказ, recovery и аварийное завершение worker на каждой стадии. Для block/reserve direct-счётчик остаётся нулевым по IPv4/IPv6. Стенд запускается отдельным CI job с root/capabilities, не на роутере пользователя. Без успешного сетевого теста не объявлять fail-closed проверенным.
- [ ] UI секции показывает режим и резерв; дашборд — active/reserve/direct/blocked/monitor-error с временем. Vitest проверяет перевод, неизвестное состояние, устаревший отчёт, отключённую функцию и отсутствие секретов. Запустить Integration Gate; commit `feat: enforce and display VPN failure policy`.
