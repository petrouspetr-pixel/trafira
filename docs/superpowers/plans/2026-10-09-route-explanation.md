# Route Explanation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Объяснять действующий маршрут с указанием источника правила и честной неопределённости.
**Architecture:** Read-only адаптер получает согласованный снимок конфигурации, provenance и локальных списков; чистый анализатор вычисляет трёхзначное совпадение. UI показывает DNS-политику отдельно от фактического запроса.
**Tech Stack:** ucode, sing-box rule-set decompile, LuCI/TypeScript, Vitest.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 1.

## Global Constraints

Наследует основной план `2026-10-09-remaining-features.md`. Диагностика ничего не сохраняет в UCI, не обновляет списки и не меняет активный узел. Нельзя считать запрос DNS с роутера запросом выбранного клиента.

## Review Focus

- Alice Mode и nft bypass могут исключить трафик до sing-box.
- Раннее unknown не позволяет утверждать позднее совпадение.
- Перезагрузка между чтением JSON и карты происхождения обнаруживается по digest.
- FakeIP не используется как реальный IP при проверке geo/CIDR.
- Список содержит отрицание, логические правила или неподдержанное поле.

## Task 1: Чистый анализатор и карта происхождения

**Files:** Create `LIB/diagnostics/route_match.uc`, `LIB/singbox/provenance.uc`, `tests/route_explanation.sh`; modify `LIB/singbox/generator.uc`, `LIB/singbox/servers.uc`, `LIB/service/lifecycle.uc`.

**Interfaces:**
- `route_match.explain(config, request, sources, rulesets)` возвращает `{status, rule_index, outbound, trace, missing}`; status = `matched|direct|blocked|indeterminate`. sources = карта без секретов; rulesets = объект tag → декомпилированный source JSON либо null.
- `route_match.match_rule(rule, request, rulesets)` возвращает `yes|no|unknown` и причины в `{value, missing}`. request = `{domain, source_ip, destination_ip, port, network, protocol, inbound}`; отсутствующее protocol не угадывается из порта.
- `provenance.annotate(rule, origin)` добавляет временное внутреннее поле; `provenance.extract(config)` удаляет все такие поля и возвращает карту `{schema:1, route:[], dns:[]}`. origin = `{kind, section, list_tag}`; URL, proxy links и пароли запрещены.

- [ ] Добавить исполняемые ucode assertions в `tests/route_explanation.sh`, включая неизвестное раннее поле:

```ucode
let m = require("diagnostics.route_match");
let req = { domain: "store.example", source_ip: "192.0.2.5", port: 443, network: "tcp" };
assert(m.match_rule({ domain_suffix: "example" }, req, {}).value == "yes");
assert(m.match_rule({ source_ip_cidr: "198.51.100.0/24", domain_suffix: "example" }, req, {}).value == "no");
let config = { route: { rules: [
    { protocol: "bittorrent", action: "route", outbound: "bypass-out" },
    { domain_suffix: "example", action: "route", outbound: "vpn-out" }
], final: "direct-out" } };
assert(m.explain(config, req, {}, {}).status == "indeterminate");
```

- [ ] Выполнить `bash tests/route_explanation.sh` до реализации: ожидается ошибка отсутствующего модуля; затем реализовать модуль и повторить до PASS.
- [ ] Реализовать трёхзначные AND/OR/NOT для поддержанных полей; неизвестные поля дают unknown. AND с достоверным no остаётся no; OR с yes остаётся yes. Сопоставление IP использует `core.ip.ip_in_cidr`; регистронезависимые домены и границы суффикса нормализуются. Сверить семантику групп полей с официальной документацией установленного ядра, включая `rule_set_ip_cidr_match_source`.
- [ ] Добавить проверки A/AAAA, границы suffix, logical AND/OR/invert, regex failure, source+destination AND, protocol unknown, action sniff/resolve/route-options/reject, final и позднего перекрытого правила. Если resolve меняет неизвестный адрес, последующий CIDR-результат остаётся условным.
- [ ] Помечать правила при создании системных, секционных, серверных и DNS-правил. После prune извлечь provenance, сериализовать чистый JSON и связать карту с SHA256 именно этих байтов. При lifecycle commit/rollback переносить JSON и карту; несовпадающий digest запрещает показ чужого происхождения. Вложенные правила проверять рекурсивно; sing-box check не должен видеть внутренних полей.
- [ ] Проверить fixtures с одинаковыми правилами разных секций, prune, rollback, ошибкой записи карты и изменением конфигурации между чтениями; commit `feat: explain generated route decisions`.

## Task 2: Read-only CLI и форма диагностики

**Files:** Create `LIB/diagnostics/route_explain.uc`, `FE/tabs/diagnostic/routeExplanation.ts`, `FE/tabs/diagnostic/renderRouteExplanation.ts`, `FE/tabs/diagnostic/tests/routeExplanation.test.ts`, `tests/route_explanation_runtime.sh`; modify `trafira/files/usr/bin/trafira`, `FE/tabs/diagnostic/renderDiagnostic.ts`, `FE/tabs/diagnostic/initController.ts`, `FE/methods/shell/index.ts`, RPC ACL.

**Interfaces:** CLI `route_explain JSON` → mode `explain`, ровно один JSON аргумент до 8 КиБ; `{domain,source:{kind:"device"|"router",ip?,mac?,interface?},destination_ip?,port:443,network:"tcp",protocol?}`. Ответ `{success,generated_at,config_digest,decision,dns_policy,dns_query,selector,limitations}`. `dns_query` явно содержит `origin:"router"` либо `performed:false`; `selector` содержит только tag/name текущего узла, не адрес или реквизиты.

- [ ] Добавить runtime-тест с поддельными curl/UCI, считающими вызовы. Некорректный JSON, домен с shell-символами, запрос больше 8 КиБ и порт 65536 должны дать ошибку до запуска внешней команды. Проверить, что чтение не меняет UCI/селектор и не скачивает remote rule-set.
- [ ] Адаптер применяет `config.alice.match_device` и `routes_through_trafira` до sing-box; при недостаточных сведениях об интерфейсе/MAC не делает уверенный вывод. Учитывает nft-обход локальных сетей/Wi-Fi Calling. Копии списков ограничены текущей квотой; декомпиляция только локальных доверенных путей с ограничением времени и вывода. Недоступный актуальный список даёт unknown, а не заменяется произвольной старой копией.
- [ ] Добавить контроллер с отменой устаревших результатов:

```ts
export type Decision = 'matched' | 'direct' | 'blocked' | 'indeterminate';
export interface ExplainRequest {
  domain: string;
  source: { kind: 'device' | 'router'; ip?: string; mac?: string; interface?: string };
  destination_ip?: string;
  port: number;
  network: 'tcp' | 'udp';
  protocol?: string;
}
// Controller.submit(request): Promise<void>; unmount(): void.
// Каждый submit увеличивает generation; рендер разрешён только последнему запросу.
```

- [ ] В Vitest проверить A-start/B-start/B-complete/A-complete, unmount, ошибку RPC и HTML в имени секции. Render использует текстовые узлы, unknown показывает причины, применённую конфигурацию и значения порта/протокола; trace ограничен 200 строками с явной отметкой усечения. Ограничение вывода не останавливает вычисление до первого завершающего правила: если исчерпан вычислительный бюджет, результат indeterminate. DNS-запрос опционален и не смешивается с анализом политики клиента.
- [ ] Запустить целевые backend/frontend тесты и Integration Gate основного плана; commit `feat: add route explanation diagnostics panel`.
