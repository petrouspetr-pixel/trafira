# Gaming Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Создавать редактируемые правила «магазин/вход через выбранную секцию, остальное напрямую» для одного устройства.
**Architecture:** Версионируемый каталог описывает домены и ограничения; чистый builder создаёт две упорядоченные части маршрутизации. Предпросмотр конфликтов и применение используют диагностику и транзакцию предыдущих этапов.
**Tech Stack:** JSON catalog, ucode, UCI, LuCI TypeScript, shell/Vitest.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 6.

## Global Constraints

Наследует основной план. Steam, PlayStation, Xbox, Epic Games. Не добавлять общий обход UDP; не открывать входящие порты/UPnP. Общие CDN не обещают точного отделения игрового сеанса. Автоматическое обновление доменных правил без diff запрещено.

## Review Focus

- Те же endpoints обслуживают магазин и игру; ограничения видны до применения.
- IPv6 privacy address или новый DHCP address изменяет соответствие устройству.
- Alice bypass/full-route перекрывает создаваемые правила.
- Повторное применение дублирует правила или уничтожает пользовательские изменения.
- Неизвестное имя устройства/платформы не должно создавать wildcard для LAN.

### Task 1: Проверенный каталог и чистый builder

**Files:** Create `trafira/files/usr/share/trafira/gaming-presets.json`, `LIB/config/gaming_presets.uc`, `tests/gaming_presets.sh`, `docs/gaming-presets-sources.md`; modify `LIB/config/validator.uc`, `LIB/singbox/generator.uc` для метаданных происхождения пресета.

**Interfaces:** Catalog `{schema:1,presets:[{id,revision,checked_at,sources,domains,limitations}]}`; id = `steam|playstation|xbox|epic`. Каждый domain = `{value,match:"exact"|"suffix",purpose:"store"|"auth"|"shared",source}`. `gaming_presets.build(preset,request,current)` → `{valid,errors,patch,conflicts}`; request = `{device_ips,proxy_section,placement,expected_digest}`. patch содержит typed UCI section additions, порядок и owner ID; без произвольных shell-фрагментов.

- [ ] Зафиксировать источники Steam/Epic и отдельно пройти официальные страницы магазина/входа PlayStation/Xbox. Для каждого production-домена сохранить публичную первичную ссылку, назначение и дату. Не брать портовые списки за доказательство назначения домена. Общий сервис авторизации отметить shared; неподтверждённые домены не включать.
- [ ] Источники для проверки:
  - Steam: https://help.steampowered.com/en/faqs/view/2EA8-4D75-DA21-31EB
  - Epic: https://www.epicgames.com/help/c-36624475/c-35761596/which-domains-need-to-be-whitelisted-to-reach-the-epic-servers-a15422130?lang=en-US
  - PlayStation: https://www.playstation.com/en-us/support/account/sign-in/
  - Xbox: https://www.xbox.com/ — проверять публичные ссылки магазина и входа, не выполняя авторизацию.
- [ ] Написать тесты builder на искусственном каталоге, независимо от живых доменов:

```ucode
let g = require("config.gaming_presets");
let preset = {id:"steam",revision:1,domains:[{value:"store.example",match:"exact",purpose:"store"}],limitations:[]};
let req = {device_ips:["192.0.2.5/32","2001:db8::5/128"],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"};
let current = {sections:[{name:"vpn",enabled:true,action:"proxy"}],digest:"test"};
let result = g.build(preset,req,current);
assert(result.valid);
assert(length(result.patch.sections) == 2);
assert(!g.build(preset,{device_ips:[],proxy_section:"vpn",placement:"before-device-routes",expected_digest:"test"},current).valid);
```

- [ ] Запустить `bash tests/gaming_presets.sh` до реализации. Builder ограничивает адреса отдельными host /32 и /128, не принимает 0.0.0.0/0, ::/0, multicast, unspecified. UI выбирает известное устройство, затем явно показывает адреса; MAC не выдаётся за вечную привязку IP. При смене DHCP/IPv6 адреса подсказка требует обновления профиля устройства, без расширения на весь subnet.
- [ ] Первая часть — domain AND device source через proxy; вторая — остаток source напрямую. DNS-сопоставление учитывает тот же источник и порядок. Добавить fixtures с магазином/игрой на одном домене, чужим устройством, ошибочным source OR domain, IPv6, FakeIP и disabled proxy section. Commit `feat: define editable device gaming presets`.

### Task 2: Предпросмотр, конфликты и транзакционное применение

**Files:** Create `LIB/config/gaming_cli.uc`, `tests/gaming_preset_apply.sh`, `FE/tabs/diagnostic/gamingPresetPanel.ts`, `FE/tabs/diagnostic/renderGamingPresets.ts`, `FE/tabs/diagnostic/tests/gamingPresetPanel.test.ts`; modify CLI, `FE/tabs/diagnostic/renderDiagnostic.ts`, controller, RPC ACL, README и переводы.

**Interfaces:** CLI `gaming_preset_action JSON`, actions `catalog|preview|apply|remove`; preview → `{patch,conflicts,limitations,expected_digest}`. apply требует явного `placement` и неизменившегося digest; использует `config_transaction.apply`. UCI metadata `preset_owner`, `preset_revision`, `preset_original_digest` позволяет отличить созданные правила от чужих и обнаружить пользовательское редактирование.

- [ ] Runtime-тесты конфликтов сначала должны падать:

```json
[
 {"scenario":"alice-bypass","expected":"conflict-no-apply"},
 {"scenario":"full-route-before-preset","expected":"explicit-priority-required"},
 {"scenario":"same-preset-again","expected":"no-duplicates"},
 {"scenario":"user-edited-preset","expected":"show-diff-before-replace"},
 {"scenario":"remove-preset","expected":"keep-unowned-sections"},
 {"scenario":"config-changed-after-preview","expected":"conflict-no-apply"}
]
```

- [ ] Мастер показывает платформу → устройство и адреса → proxy section → два создаваемых маршрута → конфликты/ограничения. У Alice bypass недостаточно переместить sing-box правило: предложить явное включение выбранного устройства в обработку Trafira с отдельным diff. Если точечное изменение нельзя выразить без изменения других устройств, заблокировать применение и объяснить конфликт.
- [ ] Размещение до/после существующих device rules выбирается явно; системные защитные DNS/FakeIP правила всегда раньше. Диагностика проверяет синтетические store и остаточные направления; unknown отображается как неполная проверка. Runtime generation/check и rollback обязательны даже после успешного preview.
- [ ] Remove удаляет только правила с matching owner. Если они отредактированы, UI предлагает сохранить как обычные правила либо явно удалить с показом diff. Обновление каталога не переписывает UCI; пользователь отдельно открывает изменения версии и применяет их.
- [ ] Vitest: устройство отсутствует, IPv6 не выбран, HTML в имени, конфликт Alice, подтверждение приоритета, stale digest, повторное применение, reconnect после долгого worker. Запустить targeted tests и Integration Gate; commit `feat: add gaming preset wizard with conflict preview`.
