# WARP Component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution or superpowers:subagent-driven-development if the user chooses delegated execution. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить необязательный WARP с отдельной страницей LuCI, безопасным подключением к Trafira и автономным восстановлением.

**Architecture:** Три отдельных пакета в `components/warp/`; основной Trafira предоставляет ограниченный адаптер и координатор операций, но не получает обязательных зависимостей от WARP. Транспорт, подбор и страница отделены от создания правил Trafira. Общие транзакции и политика отказа сохраняют рабочую конфигурацию.

**Tech Stack:** ucode v0.0.20250529, BusyBox ash, LuCI JS/rpcd, Go/AmneziaWG/WarpScout, nftables, OpenWrt SDK, Python unittest, Node/Vitest, Linux network namespaces.

**Spec:** [Согласованный проект](../specs/2026-10-09-warp-component-design.md), согласован пользователем сообщением «Давай» после просмотра проекта. План требует отдельного просмотра перед реализацией.

## Global Constraints

- «Релиз и установка на физический роутер — отдельные действия».
- «Основной пакет Trafira не зависит от WARP».
- «В первой версии поддерживается один управляемый WARP-туннель».
- «Сборки: IPK для OpenWrt 24.10 и APK для 25.12, сначала aarch64_cortex-a53 для целевого роутера».
- «Неподдерживаемая архитектура отклоняется до изменений пакетов».
- «Порядок блокировок: сначала блокировка операций Trafira, затем блокировка WARP; обратный порядок запрещён».
- «Быстрый подбор ограничен 180 секундами, полный — 900; HTTPS-проба — 8 секундами».
- «Отмена завершает запрос и дочерние процессы не позднее 10 секунд».
- «Источник обновлений — собственные релизы `petrouspetr-pixel/trafira`».
- «Не изменяются настройки ZeroTier, других VPN, LAN, глобального DNS и firewall OpenWrt».
- «Не создаём обращения или PR в исходных проектах».
- Код исходного WARP зафиксирован на `72cfeef7f1838ad991ed6242188621df2691e86a`. WarpScout v0.16.0 соответствует commit `db4ac9ebae8d942191b8e8351f2c3a37a375bd66`; AWG v3.1.20260828 и source SHA256 берутся из проверенного Makefile исходного пакета.
- Не выполнять удалённые установщики, не регистрировать настоящий Cloudflare-аккаунт в CI; внешние ответы регистрации — фикстуры. Соблюдать лицензии отдельных пакетов и сохранить авторство.
- Никакого общего исключения «весь UDP к Cloudflare». Чужие секции, процессы, ключи и интерфейсы не изменяются.

## Review Focus

1. Выключенный пользователем WARP после обновления должен остаться выключенным — задача 7.
2. Повторно использованный PID и оборванная запись журнала не должны приводить к убийству чужого процесса или потере восстановления — задача 2.
3. Userspace-AWG нельзя считать обычным kernel WG; его транспорт должен работать при включённой маршрутизации роутера — задачи 3 и 8.
4. Пока открыт предпросмотр, пользователь может изменить секцию или включить транзакцию профиля; старое подтверждение не должно перезаписывать изменения — задача 5.
5. Одновременно с подбором обычное приложение может обращаться к Cloudflare; его пакеты не должны получить обход прокси — задачи 4 и 8.

## Структура и границы модулей

Сокращения далее: `LIB=trafira/files/usr/lib`, `W=components/warp/luci-app-trafira-warp`, `WR=W/root`, `FE=fe-app-trafira/src/trafira`.

- `components/warp/UPSTREAM.json`, `NOTICE.md`: версии, происхождение файлов, лицензии; отдельно LICENSE в каждом пакете.
- `W/Makefile`, `components/warp/trafira-warp-awg/Makefile`, `components/warp/trafira-warp-scout/Makefile`: три SDK-пакета с отдельными namespace.
- `WR/usr/lib/trafira-warp/warp/{state,job,transport,scout,stability}.uc`: состояние, задания/восстановление, туннель, подбор, статистика. CLI-обёртки `WR/usr/libexec/trafira-warp-*` не содержат вторую реализацию этой логики.
- `LIB/integrations/{warp_model,warp_transport,warp_cli}.uc`: чистая модель секции, проверенный статус транспорта, адаптер общего координатора.
- `LIB/components/warp_packages.uc`: совместимый набор пакетов, установка и откат.
- `W/htdocs/luci-static/resources/view/trafira-warp/main.js`, RPC/ACL/menu в `WR/usr/share/`: отдельная страница, только очищенный статус в read ACL.
- `scripts/build-warp.sh`, `.github/workflows/warp-ci.yml`: сборка и тестирование без публикации.
- `tests/warp/`: тесты и фикстуры дополнения; `tests/warp_*.sh`: интеграция с существующим backend CI.

## Контракты между задачами

Статусы используют `success`, `error` (стабильный код), `job_id`, `running`, `restored`, `rollback_error`. Нельзя смешивать их с исходным `ok/code` на границе API Trafira.

`TransportStatus={schema:1,owner:"trafira-warp",interface,endpoint,listen_port,fwmark,running,handshake_age,https_ok,warp}`. Это очищенный объект, без account/config/private_key. Обязательные сетевые поля проходят отдельную проверку типов, адресов, портов и принадлежности интерфейса.

`WarpRequest={action,expected_digest?,preview_id?,mode?,duration?,services?}`. Разрешены только `status`, `register`, `enable`, `disable`, `reconnect`, `preview_attach`, `attach`, `preview_detach`, `detach`, `unregister`, `scan_start`, `scan_apply`, `test_start`, `cancel`, `job_status`. Лимит JSON 16 КиБ; произвольных shell/path/URL/endpoint в запросе нет. Выбор endpoint — по идентификатору сохранённого проверенного результата.

`warp_model.attach(document, transport, expected_digest, actual_digest)` возвращает `{success,document?,section?,changed?,error?}`. `warp_model.references(document,interface)` возвращает все секции со ссылкой на интерфейс. `warp_model.detach(document,section,expected_digest,actual_digest)` удаляет только проверенные собственные объекты и явно выбранную секцию; чужие ссылки блокируют удаление транспорта.

`warp_transport.read()` возвращает проверенный TransportStatus либо `{success:false,error}`. `warp_transport.exemptions(status)` возвращает `{vpn:[{ip,port}],vpn_ports:[port],interfaces:[name],fwmark}` только при подтверждённой принадлежности.

`warp.state.load(path)`, `warp.state.save(path,value)`, `warp.state.public_status(value)`; `warp.job.start(request)`, `warp.job.status(job_id)`, `warp.job.cancel(job_id)`, `warp.job.recover()`; `warp.transport.status()`, `warp.transport.apply(candidate)`, `warp.transport.restore(snapshot)`; `warp.scout.run(mode,mark)`, `warp.stability.run(duration,services)`.

Эти модули дополнения запускаются с `ucode -L /usr/lib/trafira-warp`; интеграция Trafira — с `ucode -L /usr/lib/trafira`. Между пакетами передаётся ограниченный JSON, исходники с разными лицензиями не склеиваются в общий модуль.

## Подготовка

- [ ] Переиспользовать изолированную рабочую копию, проверить отсутствие посторонних изменений и создать ветку реализации от согласованного проекта/плана. Зафиксировать SHA main. Не запускать release workflow.
- [ ] Проверить происхождение и лицензию каждого импортируемого файла и зависимостей Go. Составить UPSTREAM.json до переноса; сохранять исходные уведомления. При несовместимом условии изолировать пакет/заменить адаптер собственной реализацией, не удалять лицензии.
- [ ] Выполнить базовый frontend и backend CI. Windows без ucode не считается выполнением backend-тестов; использовать Linux CI с тем же ucode, что у проекта.

## Задача 1: Устанавливаемые пакеты без сетевых побочных действий

**Files:** Create `components/warp/UPSTREAM.json`, `components/warp/NOTICE.md`, три Makefile и LICENSE, `WR/etc/config/trafira-warp`, `tests/warp/test_package_identity.py`, `scripts/build-warp.sh`, `.github/workflows/warp-ci.yml`.

**Interfaces:** Consumes закреплённые исходники; Produces три пакета, конфигурацию disabled по умолчанию и каталог staging без модификации Trafira/network.

- [ ] Написать тест артефакта: распаковать каждый тестовый пакет в временный root, проверить namespace и отсутствие сетевой установки в postinst.

```python
from pathlib import Path
import unittest
class PackageIdentity(unittest.TestCase):
    def test_optional_identity(self):
        text = Path('components/warp/luci-app-trafira-warp/Makefile').read_text()
        self.assertIn('luci-app-trafira-warp', text)
        core = Path('trafira/Makefile').read_text()
        self.assertNotIn('+luci-app-trafira-warp', core)
        config = Path('components/warp/luci-app-trafira-warp/root/etc/config/trafira-warp').read_text()
        self.assertIn("option enabled '0'", config)
```

- [ ] Запустить `python3 -m unittest discover -s tests/warp -p 'test_package_identity.py'`; увидеть FAIL на отсутствующих файлах. Дополнить проверкой реального install/postinst в изолированном root: хеши исходных network/trafira не меняются, вызовов регистрации/ifup нет.
- [ ] Перенести сборочные определения с явными именами и зависимостями, добавить метаданные происхождения и конфигурацию:

```uci
config settings 'main'
    option enabled '0'
    option interface_prefix 'tfwarp'
    option mtu '1280'
```

Собирать AWG и Scout из закреплённых исходников SDK, а не копировать непроверенные готовые бинарники из dist. `scripts/build-warp.sh <x.y.z> <opkg|apk> <aarch64_cortex-a53> <out>` отклоняет неподдерживаемую архитектуру до скачивания; SDK, toolchain и SHA256 зафиксированы. CI публикует только job artifacts, не GitHub Release.
- [ ] Пройти тест и сборку обоих форматов, проверить архитектуру, зависимости, лицензии, отсутствие незаменённых шаблонов; commit `build: add isolated optional WARP packages`.

## Задача 2: Задания, секреты, общий координатор и восстановление

**Files:** Create `WR/usr/lib/trafira-warp/warp/state.uc`, `job.uc`, `WR/usr/libexec/trafira-warp-job`, `LIB/integrations/warp_cli.uc`, `tests/warp_jobs.sh`; Modify `trafira/files/usr/bin/trafira-config`.

**Interfaces:** Consumes `service.operation_lock.acquire/release`, `core.storage`; Produces state/job API и `trafira-config warp_action <JSON>`.

- [ ] Написать тест удаления секретов и атомарного состояния, запустить `bash tests/warp_jobs.sh`, увидеть отсутствие модуля:

```ucode
let state=require("warp.state");
let result=state.public_status({running:true,private_key:"fixture-secret",token:"fixture-token",account:{id:"private"}});
assert(result.running==true,"public running state");
assert(index(sprintf("%J",result),"fixture-secret")<0,"no key in status");
assert(!result.account && !result.token,"no registration in status");
```

- [ ] Реализовать строгий allowlist public_status; файлы 0600/каталоги 0700, exclusive staging, readback и атомарный rename. Журнал schema1 включает PID+start ticks, стадию, предыдущее состояние, ожидаемый digest и собственные объекты; секреты находятся только в приватной резервной копии. Статусы/лог в RAM ограничить 2 МиБ; старый завершённый статус заменяется новым, журнал незавершённой операции не удаляется.
- [ ] Изменяющий RPC стартует независимый координатор Trafira; тот захватывает общий lock, затем запускает дочерний WARP worker с его собственным lock. Отмена — приватный cancel-файл без захвата занятой общей блокировки, работник проверяет его; SIGTERM/SIGKILL только подтверждённой группе своих процессов. Watchdog использует тот же координатор. Read-status не захватывает lock изменения.

```ucode
let allowed=["status","register","enable","disable","reconnect","preview_attach","attach","preview_detach","detach","unregister","scan_start","scan_apply","test_start","cancel","job_status"];
function valid_action(request){return type(request)=="object" && index(allowed,request.action)>=0;}
```

- [ ] Проверить реальные отдельные процессы: разрыв родителя не прерывает job; конкурентный profile/core job получает busy; повторный PID не убивается; SIGKILL на каждой стадии восстанавливает журнал; повреждённый журнал сохраняется с recovery_error; отмена завершается до 10 с; места для backup недостаточно — изменений нет. Backend CI RED→GREEN, commit `feat: coordinate WARP jobs with safe recovery`.

## Задача 3: Принадлежащий дополнению userspace-AWG

**Files:** Create `WR/usr/lib/trafira-warp/warp/transport.uc`, `WR/usr/libexec/trafira-warp-awg-runner`, `WR/etc/init.d/trafira-warp`, `LIB/integrations/warp_transport.uc`, `tests/warp_transport.sh`; Modify `components/warp/trafira-warp-awg/files/warp-awgctl.c` (перенесённый отдельный контроллер).

**Interfaces:** Consumes task 2 journal/locks; Produces очищенный TransportStatus, transport.apply/restore, проверенные exemptions.

- [ ] Написать `bash tests/warp_transport.sh` с подменёнными ip/uci/UAPI: чужой tfwarp0 → выбирается tfwarp1; все 10 заняты → interface_conflict без изменений; IPv6 выключен → только IPv4; неверный mark/endpoint → отказ до ifup. Первый запуск RED: нет transport-модуля.
- [ ] Перенести runner с отдельными путями; проверять сокет UAPI, процесс, владельца сетевой секции и device. Статус брать ограниченными полями, не через dump с ключами. Применять:

```uci
config interface 'tfwarp0'
    option proto 'none'
    option device 'tfwarp0'
    option auto '0'
    option defaultroute '0'
    option peerdns '0'
    option delegate '0'
    option trafira_warp_managed '1'
```

Имя здесь — образец выбранного свободного интерфейса; не константа для перезаписи. Транспортный FwMark передаётся координатором из действующих constants Trafira; кандидат отклоняется при конфликте с захватывающей меткой/mwan3. Нет изменения default route, системного DNS или ZeroTier.
- [ ] Проверить handshake и HTTPS отдельно, адреса и порт только из валидированного аккаунта. Endpoint-смена сохраняет интерфейс; при ошибке восстанавливаются старый runtime и состояние enabled. Заблокировать выключение регистрации/удаление интерфейса с оставшимися ссылками. Добавить тест подложного status-файла и симлинка, отсутствующего UAPI и умершего PID; не сообщать об успехе по одному наличию файла.
- [ ] Пройти фикстуры и реальный loopback userspace-AWG тест в Linux, без Cloudflare; commit `feat: manage isolated WARP transport`.

## Задача 4: Прямой подбор без широких исключений

**Files:** Create `components/warp/trafira-warp-scout/patches/100-socket-mark.patch`, `WR/usr/lib/trafira-warp/warp/scout.uc`, `stability.uc`, `WR/usr/share/trafira-warp/services.tsv`, `tests/warp_scout.sh`, `tests/warp_stability.sh`.

**Interfaces:** Consumes job cancellation и transport; Produces scout.run(mode,mark), stability.run(duration,services), сохранённые проверенные candidate ID.

- [ ] Сначала воспроизвести отсутствие метки в исходном WarpScout: его `bind.go` содержит `deviceBind.SetMark(uint32) error { return nil }`. В Linux-тесте открыть UDP bind, прочитать SO_MARK через getsockopt и ожидать переданное значение; исходник должен дать RED.
- [ ] Патч к закреплённому Scout хранит mark в deviceBind, применяет его через Control при Open и к уже открытому сокету при SetMark. Параметр `-fwmark` передаётся из ограниченного менеджера; ошибка setsockopt фатальна. Обработка интерфейса SO_BINDTODEVICE сохраняется. Для регистрации/служебного DNS маркируются только выделенные исходящие сокеты; не меняется глобальный DefaultTransport для произвольных запросов. Встроенный автоматический proxy/alternate-protocol fallback отключается, используется только выбранный прямой режим AWG.

```go
func setSocketMark(fd int, mark uint32) error {
    return unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_MARK, int(mark))
}
```

Этот helper размещается в Linux-патче с `golang.org/x/sys/unix`; вызовы в Open/SetMark проверяются фактическими getsockopt и пакетными счётчиками. Полный patch включает передачу ошибки Control и rawconn.Control, а не игнорирует ошибку callback.
- [ ] Ограничить быстрый/полный подбор 180/900 с, HTTPS 8 с; группы процессов принадлежат job. Candidate ID связан с digest регистрации, job и проверенным endpoint, повторная проверка перед применением. DNS/HTTPS стабильности привязаны к WARP и реальным IP, никогда к FakeIP. Статистика: ошибки по этапам, HTTP-коды, медиана/p95 и warp=on/plus отдельно. Разрешены длительности 15/30/45/60 минут и только service ID из каталога. Смена transport generation завершает тест с частичным результатом.
- [ ] RED→GREEN: job cancel убирает все дочерние процессы; чужой UDP к тому же IP остаётся без mark; перезапуск меняет generation; 403/429 не считаются доказательством поломки туннеля; FakeIP и неверный candidate отвергаются. `go test ./...` в patched Scout, два shell-теста; commit `feat: add bounded WARP discovery and stability checks`.

## Задача 5: Предпросмотр и транзакционное подключение к Trafira

**Files:** Create `LIB/integrations/warp_model.uc`, `tests/warp_attach.sh`; Modify `LIB/integrations/warp_cli.uc`, `LIB/config/validator.uc` только для новых служебных полей при необходимости.

**Interfaces:** Consumes очищенный transport, profile_format/profile_runtime/config_transaction; Produces attach/references/detach и preview_attach/attach/preview_detach/detach.

- [ ] Написать чистый тест ожидаемой структуры и конфликтов, запустить `bash tests/warp_attach.sh`, получить RED:

```ucode
let model=require("integrations.warp_model");
let doc={schema:1,name:"fixture",config:[{".name":"settings",".type":"settings"}]};
let transport={schema:1,owner:"trafira-warp",interface:"tfwarp0",running:true,https_ok:true,warp:"on"};
let result=model.attach(doc,transport,"a","b");
assert(!result.success && result.error=="conflict","stale preview does not mutate config");
assert(length(doc.config)==1,"input document remains intact");
```

- [ ] Создать современную секцию `action=connection`, `failure_policy=block`, пустые списки и дочерний section_interface с привязкой к выбранной секции. Дочерний объект имеет `.type=section_interface`, `section=<имя созданной секции>`, `name=<имя интерфейса>`; поле section соответствует текущему config.connections.child_items, порядок сохраняется по принятому в текущей UCI представлению. Проверить реальный генератор на этих полях. Служебный owner=`trafira-warp`; отдельная каноническая исходная копия только собственных полей выявляет ручные изменения. Чужая cfwarp выбирает следующее свободное имя без перезаписи. Повторное добавление неизменённого интерфейса идемпотентно.
- [ ] Предпросмотр готовит профиль в private staging, проверяет generator+sing-box; значения секретов не входят в diff. Preview ID связан с digest UCI и transport generation, TTL 15 минут. Apply повторно проверяет их под lock. Координатор уже владеет lock: использовать prepare/validate и config_transaction.apply в этом worker, а не запускать profile_job, который ждёт тот же lock. Сбой восстанавливает оригинальную UCI и службы; остановленная Trafira остаётся остановленной.
- [ ] Тестировать настоящий генератор на изолированном UCI: binding, policy/DNS, отсутствие изменений соседних секций, уже занятое имя, ручные правки, перенос ссылки другим разделом, отказ ядра после commit и восстановление. Удаление сначала показывает изменение маршрута, удаляет только подтверждённые собственные объекты; удаление транспорта блокируется любой оставшейся ссылкой. Whole backend GREEN; commit `feat: attach WARP through Trafira configuration transactions`.

## Задача 6: Отдельная страница LuCI и перевод

**Files:** Create `W/htdocs/luci-static/resources/view/trafira-warp/main.js`, `WR/usr/share/rpcd/ucode/trafira_warp.uc`, `WR/usr/share/rpcd/acl.d/luci-app-trafira-warp.json`, `WR/usr/share/luci/menu.d/luci-app-trafira-warp.json`, `W/po/ru/trafira-warp.po`, `tests/warp/test_view.cjs`, `tests/warp_rpc.sh`.

**Interfaces:** Consumes WarpRequest/status/job API; Produces страница «WARP для Trafira», без дублирования выбора сайтов или устройств.

- [ ] Написать Node-тест со stub rpc/form: закрытие страницы прекращает polling, но не cancel; повторное открытие подхватывает job; attach требует актуального preview; pending disables mutating controls. Запустить `node --test tests/warp/test_view.cjs`, RED на отсутствующем модуле. Подобрать fixture UI harness из исходных `test_autotune_view.cjs` с сохранением лицензии.
- [ ] Реализовать RPC allowlist с JSON ≤16 КиБ, типизированными аргументами и ограниченным выводом. Read содержит только status/job_status; cancel и все изменения — write. Регистрация требует явного действия и ссылки на условия Cloudflare. Ввод/ошибки выводить textContent/LuCI E, а не innerHTML.

```json
{"luci-app-trafira-warp":{"read":{"ubus":{"luci.trafira_warp":["status","job_status"]}},"write":{"ubus":{"luci.trafira_warp":["action"]}}}}
```

`action` проверяет конкретный action по контракту и передаёт в общий координатор; read не предоставляет UCI-доступ к секретам или запуск shell.
- [ ] Добавить русские статусы регистрации, handshake/HTTPS, остановленной службы, недоступного API, занятой операции, несовместимых пакетов и recovery_error. В приложении нет произвольного endpoint/URL, кнопки удаления регистрации и отключения связей показывают последствия. Сохранить частичный результат отменённого теста.
- [ ] Проверить read-only ACL, отсутствие секретов в успешных/ошибочных ответах, XSS в сообщении backend, reconnect, stale preview, unknown status и ошибки RPC. Node/ucode GREEN; commit `feat: add standalone WARP LuCI management`.

## Задача 7: Компонент в обновлениях и автономный откат

**Files:** Create `LIB/components/warp_packages.uc`, `tests/warp_packages.sh`; Modify `LIB/components/action.uc`, `updates.uc`, `updater.uc`, `FE/tabs/updates/render.ts`, `initController.ts`, связанные методы componentAction и их тесты, `build.sh`/`.github/workflows/build.yml` только для будущего отдельного выпуска.

**Interfaces:** Consumes общий coordinator и transport refs; Produces component `warp`, status/install/update/remove с одинаковым внешним форматом существующих компонентов. `warp_packages.select(manifest,arch,manager)` → `{success,packages,error?}`; `warp_packages.install(selection,hooks)` → итог операции. Hooks: stage, snapshot, stop, install, verify, restore — реальные системные адаптеры в action.uc, фикстуры в тестах.

- [ ] Написать fixture manifest и тесты: неверная архитектура/неполное семейство/неверный SHA/недоступный старый пакет → ноль вызовов stop/install. Ошибка второго пакета → восстановление всей прежней тройки. Отключённая служба после успеха остаётся отключённой. `bash tests/warp_packages.sh` — RED.
- [ ] Формат manifest `schema:1`, family_version, minimum_trafira_version, packages с name/version/arch/manager/file/sha256/installed_size; ровно три ожидаемых имени. URL только собственного релиза, транспорт загрузки соблюдает текущую настройку Trafira. До замены скачать новые и предыдущие пакеты и проверить реальные metadata, не доверять одному manifest.

```ucode
function complete_family(names){
    let expected=["luci-app-trafira-warp","trafira-warp-awg","trafira-warp-scout"];
    return length(names)==3 && length(filter(expected,(name)=>index(names,name)<0))==0;
}
```

- [ ] Рассчитать peak RAM/overlay с распакованными файлами, резервом и предыдущими пакетами. Заменять семейство под общим lock; восстановить account, endpoint, enabled и UCI при ошибке; остановленный сервис не запускать для проверки, вместо этого offline check. Работавший сервис подтверждается по фактическим версиям, runtime и HTTPS. Старые данные/пакеты сохранять до проверки результата; только одна предыдущая версия, ошибки отката не чистить.
- [ ] В Trafira показать компонент и ссылку на LuCI после установки; отсутствие релизных файлов — «Пока недоступно», без fallback на upstream/main. Обновить типы, RU и собранный main.js. Документировать ручную установку семейства/обновление из собственного release manifest; удаление с refs запрещено. Проверить аппаратно-независимый dry-run postinst и package-manager mocks обоих форматов; полный frontend/backend GREEN; commit `feat: install and update optional WARP package family`.

## Задача 8: Интеграция router-origin, сетевые аварии и финальная приёмка

**Files:** Modify `LIB/nft/router_origin.uc`, `LIB/service/runtime_apply.uc`, `.github/workflows/warp-ci.yml`; Create `tests/warp_network.sh`, `tests/helpers/warp_network.py`; Modify `README.md`.

**Interfaces:** Consumes warp_transport.exemptions, состояние job/transport и действующие сетевые guard; Produces совместимая маршрутизация приложения роутера и проверка main без релиза.

- [ ] В Linux namespace собрать реальный AWG-клиент/сервер с тестовыми ключами и без Cloudflare. Включить правила Trafira router-origin, убедиться, что нынешний snapshot не распознаёт userspace transport: RED ожидает успешное подтверждённое исключение, а не снятие проверки для любого интерфейса.
- [ ] В snapshot объединять системные WG/AWG и проверенный owned transport; неподтверждённый интерфейс по-прежнему отклоняется. Добавить mark/endpoint/listen-port в исключения и журнал guard. Смена endpoint происходит под общим lock, сохраняет интерфейс и обновляет исключения до снятия защиты. Отсутствие дополнения не добавляет команд/ошибок в обычный запуск.
- [ ] Реальными сетевыми счётчиками проверить: LAN IPv4/IPv6 через выбранный WARP, обычный LAN без изменений, router-origin on/off, прямой bootstrap, HTTP через работающий туннель, остановку AWG, падение watchdog/worker, разрыв управления во время endpoint change, SIGKILL между UCI/core/nft фазами, недоступный IPv6, FakeIP/DNS. На WAN запрещены выбранные соединения при отказе; SSH/LuCI управления доступны. Параллельный обычный UDP к тому же Cloudflare IP не наследует mark сканера.

```sh
sudo env RUN_TRAFIRA_WARP_NETWORK_TESTS=1 bash tests/warp_network.sh
# Ожидается: все проверки IPv4/IPv6 и cleanup pass; запрещённые WAN-счётчики равны 0.
```

- [ ] README: необязательная установка из проверенного собственного релиза, ограничения архитектуры/userspace CPU, выбранные списки, самостоятельное обновление, безопасное удаление, восстановление и отмена. Не обещать скорость и не добавлять лицензионные утверждения без проверки исходных условий.
- [ ] Полная проверка, один независимый итоговый review по выбранному навыку исполнения; воспроизвести существенные замечания тестом до исправления. Собственный PR, прикрепление к чату, зелёные CI → merge → проверка main. Никакого тега, release dispatch или установки на физический роутер. Commit `test: verify WARP isolation and recovery across router routing`.

## Команды общей проверки

Из `fe-app-trafira`:

```sh
node node_modules/vitest/vitest.mjs run
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src --ext .ts,.tsx --max-warnings=0
node node_modules/prettier/bin/prettier.cjs --check src
node node_modules/tsup/dist/cli-default.js src/main.ts
```

В Linux из корня:

```sh
find trafira/files/usr/lib components/warp -name '*.uc' -print0 | xargs -0 -n1 ucode -c -o /dev/null
find trafira/files/usr/lib components/warp -name '*.uc' -print0 | xargs -0 -n1 ucode -S -c -o /dev/null
printf '%s\0' tests/*.sh | xargs -0 -n1 -P4 bash -c 'bash "$1"' _
python3 -m unittest discover -s tests/warp -p 'test_*.py'
node --test tests/warp/test_view.cjs
sudo env RUN_TRAFIRA_WARP_NETWORK_TESTS=1 bash tests/warp_network.sh
git diff --check
```

Оба SDK-пакетных формата проверяются в WARP CI, patched Scout проходит `go test ./...`; необходимые Linux привилегии ограничены изолированным сетевым job. Генерация LuCI повторно не меняет main.js. Не считать пропущенные root/network тесты успешным сетевым прогоном.

## Самопроверка плана и порядок исполнения

Задачи 1→2→3→4→5→6→7→8 последовательны: общие контракты и блокировки важнее параллельной скорости. Прежние правила Trafira и обязательные зависимости сохраняются до явного подключения компонента. Все пять Review Focus имеют сценарии в соответствующих задачах; требования спецификации покрыты пакетами (1/7), lifecycle/секретами (2/3), подбором (4), секцией (5), UI (6), router-origin/приёмкой (8).

Рекомендуется выполнение непосредственно в текущем чате, с одним независимым итоговым ревью. Статус: план подготовлен для просмотра; реализация ещё не начата.
