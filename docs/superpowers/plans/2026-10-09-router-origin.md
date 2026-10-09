# Router Origin Traffic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development according to the user's execution choice. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Отправлять пользовательские соединения самого роутера через выбранную секцию, сохранив служебный транспорт и управление.
**Architecture:** Отдельная метка и TPROXY inbound отличают локальные программы от LAN и выходов sing-box. Перехват добавляется последним в существующую output-цепочку, после явных правил и служебных исключений.
**Tech Stack:** nftables, policy routing, sing-box, ucode, LuCI JS, Linux namespaces.
**Spec:** `docs/superpowers/specs/2026-10-09-remaining-features-design.md`, раздел 5.

## Global Constraints

Наследует основной план. Default off. Не менять маршруты LAN. Существующие выбранные транспорты DNS/подписок/компонентов сохраняют приоритет. Используется политика отказа этапа 4.

## Review Focus

- Собственный outbound-mark sing-box уже равен 0x08000000: его нельзя повторно назначить новой функции.
- DNS имени VPN-сервера должен работать до поднятия VPN.
- IPv6 локальный адрес не равен разрешению вывести FakeIP напрямую.
- Удаление/отключение выбранной секции не должно молча вернуть direct.
- Перезапуск сети и смена WAN не должны оставить старые пути/метки.

### Task 1: Настройки, исключения и генерация

**Files:** Create `LIB/config/router_origin.uc`, `tests/router_origin.sh`; modify `LIB/core/constants.uc`, `LIB/singbox/constants.uc`, `LIB/singbox/generator.uc`, `LIB/singbox/route.uc`, `LIB/nft/apply.uc`, `LIB/config/validator.uc`, `LIB/service/state.uc`, `LUCI/settings.js`.

**Interfaces:** UCI `router_origin_enabled=0|1`, `router_origin_section`; `router_origin.config(settings,sections)` → `{enabled,section,error?}`. Новый origin bit `0x10000000`; перехватываемая метка сочетает его с существующим route bit `0x04000000`. Проверить отсутствие пересечений с effective marks, mwan3 и пользовательскими override; конфликт запрещает включение. Router inbounds `router-tproxy-in`/`router-tproxy6-in`, port 1605; при занятом/зарезервированном порте валидация сообщает ошибку до применения.

- [ ] Тесты default-off и порядка правил записать до реализации:

```json
[
 {"enabled":false,"packet":"router-https","expected":"legacy"},
 {"enabled":true,"packet":"router-https","expected":"selected-section"},
 {"enabled":true,"packet":"sing-box-outbound-mark","expected":"no-recapture"},
 {"enabled":true,"packet":"lan-client","expected":"legacy-lan"},
 {"enabled":true,"packet":"local-management-reply","expected":"no-recapture"},
 {"enabled":true,"packet":"bootstrap-dns","expected":"explicit-bootstrap-route"}
]
```

- [ ] Запустить `bash tests/router_origin.sh` до изменений. Добавить settings validation, signature и port/tag reservation. Новая секция должна существовать, быть enabled connection action; циклы с DNS/bootstrap/detour отклоняются.
- [ ] Сгенерировать отдельные IPv4/IPv6 listeners и правило только для их inbound. Сначала DNS protection и системные исключения, затем выбранный выход. Router-origin не получает неожиданно LAN Alice gate или общий torrent bypass. Добавить происхождение правил в provenance этапа 1.
- [ ] В output сохранить ранний return для собственных/провайдерских marks, loopback, локальных управляемых сетей, DHCP и NTP bootstrap. Исключения портов привязаны к назначению/служебному контексту, а не безусловному обходу всех пакетов с таким портом. Endpoint и resolver sets заполняются до перехвата и обновляются атомарно. При неизвестном bootstrap endpoint не включать перехват с риском петли.
- [ ] Ответные пакеты уже существующих входящих SSH/LuCI соединений исключить по направлению conntrack; не использовать безусловный `ct state established return`, иначе последующие пакеты нового проксируемого соединения уйдут напрямую. В prerouting выделить помеченный локальный повторный вход до общего LAN TPROXY; исходящий транспорт ядра не попадает в него повторно.
- [ ] Проверить совпадение масок `ip rule` с комбинированной меткой, резервирование port 1605 и конфликты marks. PASS → commit `feat: generate router-origin routing safely`.

### Task 2: Сетевые сценарии и диагностика

**Files:** Create `tests/router_origin_network.sh`; modify `LIB/diagnostics/route_explain.uc`, `LIB/service/lifecycle.uc`, `LUCI/settings.js`, `README.md`, CI workflow для Linux network tests.

**Interfaces:** источник `{kind:"router"}` диагностики этапа 1 выбирает router inbound и отражает исключения до sing-box. На дашборде состояние выбранной секции берётся из failure-policy status; отдельный проверяющий daemon не создаётся.

- [ ] Построить стенд router/client/wan/proxy с двумя IP-семействами. Добавить наблюдатель счётчиков, фиксирующий путь каждого fixture-запроса:

```sh
# Выполняется в отдельном Linux CI namespace, не на физическом роутере.
ip netns add trafira-router-test
ip netns add trafira-client-test
# Скрипт владеет только namespace с этими именами; cleanup удаляет только их.
# Проверки сравнивают счётчики интерфейсов и адрес источника на тестовом сервере.
```

- [ ] Проверить TCP/UDP локального процесса через proxy, LAN без изменения, direct bootstrap DNS, недоступный primary с block/reserve/direct, reconnect SSH/LuCI, уже открытый SSH, перезапуск сети и выключение функции. Перед cleanup сохранить результат; не пропускать сетевой тест при отсутствии capability как будто он прошёл.
- [ ] Для доменного VPN endpoint начать с пустого DNS-кэша и остановленного туннеля. Требовать успешный bootstrap и отсутствие растущего счётчика повторного перехвата. Изменить endpoint и WAN, проверить обновление sets без разрешения произвольного destination bypass.
- [ ] В UI объяснить, что настройка относится к приложениям роутера; показать выбранную секцию и исключения до сохранения. Ошибка применения возвращает предыдущие правила и настройку. Запустить Integration Gate; commit `test: verify router-origin networking and recovery`.
