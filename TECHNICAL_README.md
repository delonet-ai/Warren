# Warren: технический README

Этот документ хранит технические детали проекта, milestones разработки, политику версий и внутренние сценарии проверки. Основной пользовательский обзор находится в [README.md](README.md).

## Направление проекта

Центр оркестрации — роутер на OpenWrt. Пользователь должен иметь возможность зайти на роутер по SSH, запустить один entrypoint и дальше выполнить настройку роутера, Podkop, VPS, AmneziaWG, QoS, Telegram-бота, диагностики и Remote Admin из меню Warren.

Проект остаётся на `sh` и развивается в сторону модульной структуры вместо одного большого скрипта.

Поддерживаемые семейства OpenWrt:

- OpenWrt `25.x` — ожидается `apk`; основная и единственная тестируемая платформа (сейчас `25.12.5`);
- OpenWrt `24.x` — ожидается `opkg`; код поддержки сохранён, но с 2026-09-25 E2E и live regression на `24.x` не проводятся (`tools/test-e2e.sh` принимает только `--fw 25`).

Обновление прошивки: `kmod-amneziawg` собирается под точное ядро релиза. Новый point-release (например, `25.12.6` с ядром `6.12.108` вместо `6.12.94`) можно брать только после появления соответствующего релиза в `Slava-Shchipunov/awg-openwrt` и прогона E2E; затем поднять `WARREN_OPENWRT_PINNED_RELEASE` в `lib/versions.sh` и положить образ в `tools/os/`.

Patch-версия OpenWrt сама по себе не считается глобальным стоп-фактором. Исключение — компоненты, где версия напрямую связана с ABI, API или протоколом.

## Текущая модульная структура

Целевая структура:

```text
warren.sh
bootstrap.sh
lib/common.sh
lib/versions.sh
lib/ui.sh
lib/state.sh
lib/basic.sh
lib/podkop.sh
lib/vps.sh
lib/amnezia.sh
lib/amneziawg.sh
lib/tg_bot.sh
lib/qos.sh
lib/remote_admin.sh
lib/usb_modem.sh
```

Ответственность модулей:

- `warren.sh` — основной entrypoint и orchestrator.
- `bootstrap.sh` — backward-compatible wrapper.
- `lib/common.sh` — logging, retries, helpers, command wrappers.
- `lib/versions.sh` — critical dependency policy, version pins, OpenWrt family checks и AmneziaWG release resolution.
- `lib/ui.sh` — banner, terminal reset/clear, prompts, menus, summaries.
- `lib/state.sh` — state files, temporary JSON payload, cleanup, resume logic.
- `lib/basic.sh` — базовая подготовка OpenWrt и пакетная логика.
- `lib/podkop.sh` — установка и интеграция Podkop.
- `lib/vps.sh` — подключение к VPS, probing, setup и extraction generated config.
- `lib/amnezia.sh` — orchestration приватного доступа.
- `lib/amneziawg.sh` — установка AmneziaWG, server setup и управление клиентами.
- `lib/tg_bot.sh` — Telegram control bot для Podkop и AmneziaWG clients.
- `lib/qos.sh` — traffic shaping и policy profiles.
- `lib/remote_admin.sh` — Remote Admin bootstrap, router agent, VPS helper и tunnel orchestration.
- `lib/usb_modem.sh` — будущие modem-related flows.

## Где Warren хранит данные

Постоянные данные Warren на роутере:

- `/etc/warren` — конфиги, state и VPS-отчёты;
- `/root/warren` — логи и диагностические файлы.

Важные пути:

- VPS-отчёты: `/etc/warren/vps/reports`;
- SSH-ключи для VPS: `/etc/warren/vps/keys`;
- диагностика: `/root/warren/warren-diagnostics`;
- SNI-кандидаты на роутере: `/etc/warren/sni-checker/sni-candidates.txt`;
- SNI-отчёты на роутере: `/etc/warren/sni-checker/reports`.

## Локальные артефакты и быстрые проверки

Firmware (`tools/os`), E2E-прогоны (`tools/test-runs`), diagnostics и generated bundles не являются исходным кодом и игнорируются Git. E2E создаёт каталоги с правами `0700`, файлы с правами `0600` и маскирует proxy links, пароли и API tokens в копии Warren log. Скопированный `vps-report.txt` остаётся приватным локальным файлом и может содержать рабочие доступы.

`.warren-router-upload` больше не является второй tracked-копией исходников. Одноразовый upload bundle строится из актуального tree:

```sh
sh tools/build-router-upload.sh
```

Все проверки, не требующие роутера или сети:

```sh
sh tools/check.sh
```

В них входят syntax checks (sh/bash/python), проверка runtime-манифеста, 51 POSIX shell regression check для version policy, config parser, state, URL generation, Podkop runtime health, Remote Admin lifecycle, retry/integrity, security hardening, Watchdog state machine и graceful OpenWrt policy, а также проверка сборки upload bundle.

## Управление версиями и зависимостями

Warren не пинит все OpenWrt-пакеты. Большинство пакетов (`curl`, `wget`, `ca-certificates`, `qrencode`, `tcpdump`, LuCI runtime и другие) должны ставиться штатным пакетным менеджером текущего OpenWrt.

Критичные компоненты:

- `OpenWrt` — аппаратный E2E пинит проверенный образ NanoPi R5S `25.12.5` и его SHA256; rolling `SNAPSHOT` не считается совместимым, пока для его точного ядра нет AWG-пакетов.
- `Podkop installer` — Warren пинит installer на release `0.7.21` и проверяет SHA256, но не управляет зависимостями Podkop.
- `3x-ui` — Warren пинит release `v3.5.0` и SHA256 installer, потому что setup зависит от API, путей панели, SQLite/API token и Reality inbound behavior.
- `AmneziaWG` — Warren использует внешний источник `Slava-Shchipunov/awg-openwrt`, потому что готовых official OpenWrt packages в текущем flow нет.
- `Warren bundle` — `warren.sh`, `lib/*.sh`, LuCI controller/view/menu/ACL и runner должны быть одной совместимой версии.
- `Remote Admin bundle` — router agent, VPS helper и Mac control script должны говорить одним protocol version.

`sing-box` и `xray` не пинятся как отдельные пакеты Warren. Их ставят Podkop или `3x-ui`. Warren проверяет поведение:

- запущен ли `sing-box`/`xray`;
- проходит ли `sing-box check` для конфига;
- доступна ли генерация Reality keys через `sing-box generate reality-keypair`, bundled `xray x25519` или system `xray x25519`.

### AmneziaWG exact/fallback policy

AmneziaWG — самый чувствительный к версиям компонент, потому что `kmod-amneziawg` зависит от OpenWrt release, kernel build, architecture и target/subtarget.

Основной путь:

1. Warren определяет `DISTRIB_RELEASE`, arch и target/subtarget роутера.
2. Warren выбирает release `Slava-Shchipunov/awg-openwrt` строго как `v${DISTRIB_RELEASE}`.
3. Warren проверяет наличие всех нужных пакетов до установки:
   - `kmod-amneziawg`;
   - `amneziawg-tools`;
   - `luci-proto-amneziawg` для AWG 2.0;
   - `luci-app-amneziawg` только для старого AWG 1.0 path.
4. Только если весь комплект найден, Warren начинает установку.

Проверка наличия идёт через `wget --spider` (пакеты не скачиваются) с тремя попытками `0s/5s/15s`: сразу после перезапуска Podkop DNS/маршрутизация могут быть недоступны несколько секунд, и временный сбой не должен уводить resolver на fallback.

Fallback path:

- fallback разрешён только внутри той же OpenWrt family **и только если релиз-кандидат собран на том же ядре**, что и роутер (`uname -r` против `linux_kernel.version` из `downloads.openwrt.org/releases/<rel>/targets/<target>/<subtarget>/profiles.json`); в `25.12.x` ядро меняется в каждом point-release, поэтому на практике работает только exact;
- `24.x` никогда не fallback-ится на `25.x`;
- `25.x` никогда не fallback-ится на `24.x`;
- сначала пробуются ближайшие меньшие или равные patch-релизы;
- потом пробуются ближайшие более новые patch-релизы;
- в shell режиме Warren спрашивает подтверждение;
- в LuCI режиме Warren пробует fallback автоматически и пишет решение в log;
- force-install не используется: если `opkg`/`apk` отвергает `kmod-amneziawg`, установка останавливается.

## Когда выполняются проверки

При старте Warren:

- загружается `lib/versions.sh`;
- выставляются default pins для Podkop installer и `3x-ui`, если пользователь не задал env override.

Во время basic setup:

- проверяется, что OpenWrt family поддерживается;
- проверяется соответствие package manager: `24.x/opkg`, `25.x/apk`.

Во время установки Podkop:

- используется pinned Podkop installer URL;
- зависимости Podkop остаются под контролем Podkop installer.

Во время установки AmneziaWG:

- выполняется exact/fallback resolver;
- проверяется комплект AWG package artifacts;
- установка идёт только через штатный `opkg` или `apk`.

Во время diagnostics:

- пишется блок `VERSION POLICY`;
- пишется блок `AMNEZIAWG VERSION POLICY`;
- показывается exact/fallback/missing статус AWG release;
- проверяются `sing-box`/`xray` runtime и Reality generation paths.

## Telegram-бот для Podkop

Скрипт умеет поставить на OpenWrt сервис `warren-tg-bot`. Он спрашивает токен бота от BotFather, опционально `chat_id`, ставит зависимости `curl` и `jq`, создаёт `/usr/bin/warren-tg-bot` и включает `/etc/init.d/warren-tg-bot`.

Основное управление идёт через кнопки:

- `Добавить в black` — бот просит домен и добавляет его в список проксирования.
- `Добавить в white` — бот просит домен и добавляет его в список исключений.
- `IP без VPN` — управление `Routing Excluded IPs`.
- `IP только с VPN` — управление `Fully Routed IPs`.
- `Выбор Endpoint` — `Auto` включает URLTest по всем endpoints, ниже идут кнопки с IP/host текущих endpoints.
- `Редактор Endpoint` — добавление и удаление endpoints.
- `Статус` — показывает IP-списки и краткое состояние.
- `Amnezia клиенты` — список, создание, QR/config и удаление AmneziaWG-клиентов.

Текстовые команды:

- `/black example.com` — добавить домен в пользовательский список `podkop.main.user_domains`.
- `/white example.com` — добавить домен в секцию `podkop.warren_whitelist` с `connection_type='exclusion'`.
- `/endpoints` — показать сохранённые VLESS/proxy endpoints.
- `/use 1` — переключить `podkop.main` на endpoint по номеру.
- `/add_endpoint vless://...` — добавить endpoint в список бота.
- `/clients` — открыть управление AmneziaWG-клиентами.
- `/amz_create phone` — создать AmneziaWG-клиента.
- `/no_vpn 192.168.1.20` — добавить IP в `Routing Excluded IPs`.
- `/vpn_only 192.168.1.30` — добавить IP в `Fully Routed IPs`.
- `/status` — показать короткое состояние.

Если `chat_id` оставить пустым при установке, первый чат, который напишет `/start`, будет автоматически привязан к боту.

## Диагностика Podkop/VPS

Пункт `Диагностика Podkop/VPS` снимает полный диагностический лог на роутере и показывает короткую сводку пользователю.

Проверяется:

- базовая связность WAN и публичных IP;
- локальный и внешний DNS;
- статус `podkop` и `sing-box`/`xray`;
- доступность VLESS endpoint по ping и TCP-порту;
- SSH-порт VPS, если известен `VPS_HOST`, иначе SSH-порт на host из VLESS;
- маршруты, policy rules, слушающие порты, релевантные `nft`-правила и логи.

Если проверка нашла проблемы, скрипт предлагает применить диагностический DNS-fallback для Podkop: `udp` DNS через `77.88.8.8`, затем перезапускает только Podkop и повторяет диагностику. После повторной проверки DNS-настройки Podkop возвращаются как были до диагностики, Podkop перезапускается ещё раз. Оба снимка и шаг восстановления сохраняются в один файл `/root/warren/warren-diagnostics/warren-diagnostics-*.log`.

## Проверка SNI-кандидатов Reality

Пункт `Проверка SNI-кандидатов Reality` берёт список доменов из `assets/sni-candidates.txt`, копирует его на роутер в `/etc/warren/sni-checker/sni-candidates.txt`, а затем на выбранный VPS в `/root/sni-checker/`.

Проверка на VPS:

- показывает hostname, OS, public IP, `ss -tulpn` и снимок firewall;
- не перезапускает `3x-ui` или `xray`;
- не меняет конфиги, порты и правила firewall;
- проверяет DNS, TCP `443`, TLS `1.3`, verify code, ALPN `h2`, HTTP/2 и время ответа;
- сохраняет отчёты в `txt` и `csv`;
- в конце предлагает лучший SNI-кандидат для `dest`, `serverNames` и клиентского `sni`.

Пункт `Применить SNI к VPS/Podkop` использует результат проверки или ручной ввод. Он меняет конфиги только после подтверждения: обновляет Warren Reality inbound в `3x-ui`, пересобирает VLESS-ссылку, обновляет VPS report и заменяет активный endpoint в Podkop. Перед изменениями сохраняется backup в `/etc/warren/sni-checker/backups`.

## Автоматический режим

`Автоматический режим` должен стать основным happy path.

Он должен:

1. Сразу спрашивать все нужные данные.
2. Сохранять их во временный JSON state file на время прогона.
3. Выполнять `Basic setup`, `Настрой мне VPS` и `Podkop`.
4. Сохранять результат в лог.
5. Показывать пользователю важные данные от `3x-ui`, подключения и VLESS.
6. Удалять временный JSON file в конце.

Ожидаемые входные данные:

- OpenWrt-side choices: expand root, preset selection, Podkop options, future QoS defaults.
- VPS-side inputs: VPS IP, root password, optional SSH port, optional preferred domain/SNI/public host values for Reality.

## Remote Admin

Remote Admin v1 реализован как rendezvous flow:

- роутер опрашивает один или несколько VPS endpoints;
- VPS держит live router catalog и короткую request queue;
- Mac control script может запросить роутер и дождаться tunnel;
- после поднятия tunnel SSH и LuCI доступны через localhost forwards.

Fresh `Настрой мне VPS` runs включают VPS-side Remote Admin helper, поэтому новый сервер готов к on-demand access сразу после обычного `3x-ui`/VLESS setup. LuCI view имеет отдельную Remote Admin config card, где endpoint lists и local ports можно сохранить до live test.

Mac-side control script находится в `tools/remote-admin/warren-remote-control.sh` и доступен через `warren remote` при запуске из checkout.

Интерактивный entrypoint:

```sh
sh warren.sh remote
```

CLI backend:

```sh
sh warren.sh remote vps add
sh warren.sh remote vps list
sh warren.sh remote vps check --vps <name>
sh warren.sh remote vps bootstrap --vps <name>
sh warren.sh remote routers --vps <name>
sh warren.sh remote connect --vps <name> --router <router-id>
sh warren.sh remote close --vps <name> --router <router-id>
sh warren.sh remote router install-agent --vps <name> --host <openwrt-host>
```

## Empty Router + Empty VPS regression

Рекомендуемый end-to-end regression path для чистого OpenWrt router и freshly reinstalled VPS.

Preconditions:

- Router flashed with clean OpenWrt image.
- VPS is clean Ubuntu/Debian install with root SSH access.
- Mac has access to Warren checkout and SSH reachability to both hosts.

Canonical flow:

1. On the router, run `sh warren.sh`.
2. Choose `0) Полный авторежим`.
3. Confirm automatic path completes: basic setup, overlay/expand-root, Podkop, Amnezia/QoS, diagnostics tools, SNI checker/apply readiness, LuCI parity, Telegram bot if enabled.
4. Run `Настрой мне VPS` from the same Warren session or immediately after it.
5. Confirm VPS setup completes: `3x-ui`, `VLESS + Reality`, VPS report, Remote Admin helper, `/var/lib/warren-remote`, cron cleanup.
6. On the Mac, open `sh warren.sh remote`.
7. Add a VPS profile for the fresh server.
8. Run `vps bootstrap` or `vps install-helper` if the helper is missing.
9. Install router agent through the Remote Admin console.
10. Create a test request, wait for polling, and verify the VPS-side SSH and LuCI tunnel ports.
11. Open temporary localhost forwards and probe router SSH plus LuCI from the Mac.
12. Run `close`, deliver one `ACTION=CLOSE` to the router agent, and confirm tunnel and request disappear cleanly.
13. Reboot the router and verify base state comes back normally.

Pass criteria:

- Empty router bootstraps without manual file edits.
- Empty VPS receives Warren remote components automatically.
- Remote Admin becomes usable only after router/VPS parts are in place.
- `list`, `status`, `request`, and `close` work on the VPS helper.
- Mac-driven Remote Admin can reach router SSH and LuCI through localhost.

## Архитектурные наблюдения и технический долг

Этот раздел фиксирует выявленные проблемы и зоны риска без привязки к конкретному milestone. Каждый пункт помечен приоритетом: `P1` — критично, `P2` — важно, `P3` — желательно.

### Безопасность

**[RESOLVED] Config parser не исполняет содержимое файла**

`load_conf_if_exists` читает только whitelist ключей и декодирует формат, который генерирует `quote_sh`, без `eval` и без sourcing файла. Строки с командами после значения и неизвестные ключи игнорируются. Поведение закреплено локальным regression test.

**[RESOLVED] Warren payload проверяется по SHA256 manifest**

Runtime payload перечислен в `SUMS.txt`; SHA самого manifest хранится в `VERSION`. Bootstrap, lazy-fetch, LuCI download и самообновление проверяют временный файл до `mv`, а mismatch удаляет download. `WARREN_SKIP_HASH_CHECK=1` оставлен только как явный dev-режим.

**[RESOLVED] `ask()` присваивает значение без `eval`**

`warren_set_var` валидирует имя переменной и использует POSIX `export name=value`. Shell-подобный пользовательский ввод остаётся строкой и не выполняется.

### Надёжность

**[RESOLVED] Сетевые загрузки используют общий retry/backoff**

Bootstrap и runtime используют три попытки с задержками `0s`, `5s`, `15s`. Симуляция двух временных отказов закреплена regression test.

**[RESOLVED] State file записывается атомарно**

`set_state` использует tmp+mv перед `sync`:
```sh
set_state() { printf "%s\n" "$1" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"; sync; }
```

**[RESOLVED] `pkg_is_installed` кэширует список пакетов**

`WARREN_PKG_INSTALLED_CACHE` заполняется одним вызовом `opkg list-installed` и сбрасывается `pkg_invalidate_installed_cache` после установки.

**[RESOLVED] Паузы `done_()`/`warn()` настраиваются**

`WARREN_DONE_SLEEP` / `WARREN_WARN_SLEEP` (default `5`), в LuCI-режиме пауз нет.

**[RESOLVED] Единый runtime-манифест**

`WARREN_LIB_LIST` / `WARREN_ASSET_LIST` / `WARREN_PAYLOAD_LIST` в `warren.sh` — единственный список; `tools/manifest.sh` раздаёт его `update-sums.sh` и `build-router-upload.sh`, `check.sh` ловит невнесённые файлы.

**[RESOLVED] Сервисные скрипты вынесены из heredoc в `payload/`**

TG-бот, Watchdog, Remote Admin agent/helper, SNI checker и QoS init — обычные файлы под SHA256-манифестом с отдельной проверкой синтаксиса. Mac-side `warren-remote-control.sh` больше не держит собственную урезанную копию router-agent.

**[P2] Remote Admin agent source-ит свой конфиг**

`payload/warren-remote-agent` читает `/etc/warren/warren-remote-admin.conf` через `.`. Файл пишет сам Warren с правами root, но нужно перевести на whitelist-парсер по образцу `load_conf_if_exists`.

### Совместимость

**[RESOLVED] OpenWrt family определяется по major release**

Все релизы семейства `24.*` используют policy `opkg`, все `25.*` — `apk`. Локальные regression tests покрывают альтернативные minor-релизы; live regression остаётся частью Milestone 4. Для семейств `26.x+` действует отдельная политика Milestone 18.

**[PARTIAL] Список режимов дублируется**

`mode_is_one_shot_service` уже выводится инверсией state-flow режимов, но режимы по-прежнему перечислены в `menu`, `run_service_mode`, save-case меню и LuCI view. Цель — реестр режимов.

### Инструменты разработки

**[P2] `tools/wg-vless-chain-diagnostics.sh` недоступен из меню Warren**

Мощный Mac-side инструмент диагностики цепочки WireGuard→OpenWrt→Podkop→VLESS находится в `tools/` и требует знания о его существовании. Его можно было бы запускать через `warren remote diag` или как подпункт пункта 11 «Диагностика».

**[RESOLVED] Мониторинг Podkop после setup**

Закрыто Milestone 17 (`lib/watchdog.sh`).

**[P3] Нет структурированного лога ошибок**

`warren.log` — append-only плоский текст. Нет способа быстро увидеть «что падало» по всем прогонам, не читая весь файл. JSON-строка с результатом каждого прогона (timestamp, mode, ok/fail, last_error) позволила бы быстро диагностировать проблемы.

---

## Milestones разработки

Этот раздел является основным источником задач и статусов roadmap.

### Milestone 4 — OpenWrt Family Broadening

Статус: `done` для `25.x` — hardware E2E 2026-09-25 на fresh OpenWrt `25.12.5`: `40 PASS / 0 FAIL`. `24.x` не тестируется (решение 2026-09-25).

Цель milestone — поддержать любой minor-релиз внутри семейств `24.x` и `25.x`, а не только `24.10` и `25.12`. Семейства не расширяются: `26.x+` — отдельная политика (Milestone 18).

Реализованное поведение:

- `warren_openwrt_family("24.05.0")` → `"24"`;
- `warren_openwrt_family("25.07.2")` → `"25"`;
- `24.x` ожидает `opkg`, `25.x` ожидает `apk`;
- `26.x+` пока отклоняется до реализации Milestone 18.

Целевое поведение:

- любой `24.x.y` → семейство `24`, package manager `opkg`;
- любой `25.x.y` → семейство `25`, package manager `apk`;
- `openwrt_release_supported()` возвращает true для любого `24.*` и `25.*`;
- AmneziaWG exact/fallback resolver получает `rel` как есть и уже умеет работать с патч-версиями; нужно убедиться, что `warren_openwrt_family` не используется как ограничитель внутри AWG resolver-а.

Что меняется в коде:

- `warren_openwrt_family()` в `lib/versions.sh`: заменить case `24.10.*|24.10` и `25.12.*|25.12` на `24.*` и `25.*`:
  ```sh
  case "$rel" in
    24.*) printf "%s" "24"; return 0 ;;
    25.*) printf "%s" "25"; return 0 ;;
  esac
  ```
- `warren_expected_pkg_manager_for_release()`: case по семейству `24` → `opkg`, `25` → `apk`;
- `openwrt_release_supported()` в `lib/common.sh`: расширить regex с `'^(24\.10|25\.12)(\.|$)'` до `'^(24|25)\.'`;
- `warren_awg_protocol_version_for_release()`: логика уже параметрична по `major.minor.patch`, не использует семейство напрямую — проверить, что всё корректно для новых minor-версий;
- `WARREN_SUPPORTED_OPENWRT_FAMILIES` в `lib/versions.sh`: обновить значение с `"24.10 25.12"` на `"24 25"`;
- все диагностические сообщения, упоминающие конкретные minor-версии, обновить.

Acceptance:

- `warren_openwrt_family "24.05.0"` → `"24"`;
- `warren_openwrt_family "25.07.2"` → `"25"`;
- `check_openwrt` проходит без ошибок на `24.05.x` с `opkg` и на `25.07.x` с `apk`;
- AmneziaWG exact/fallback resolver корректно работает на `24.05.x` (ищет tag `v24.05.x`);
- diagnostics report содержит корректный `openwrt_family` для нового релиза;
- `24.10.x` и `25.12.x` ведут себя как раньше — без регрессий.

### Milestone 5 — Amnezia + QoS Live

Статус: `done`.

Acceptance:

- AmneziaWG ставится на `24.10.x` и `25.12.x`;
- создание, список, config/QR и удаление клиентов работают из shell и LuCI;
- QoS-профили `standard`, `priority`, `bulk`, `limit_1mbit`, `limit_10mbit`, `off` применяются через `nft`;
- QoS восстанавливается после reboot.

Что осталось проверить:

- regression после fresh install;
- `Amnezia` client create/list/config/QR/delete;
- QoS profiles `apply/off`;
- сохранение после reboot.

### Milestone 6 — Diagnostics, SNI Checker, LuCI Parity

Статус: `implemented`, требуется live regression.

Рабочие tools:

- `Diagnostics Podkop/VPS`;
- emergency DNS-fallback;
- VPS-side `SNI checker`;
- SNI apply flow: проверка отдельно, применение отдельно, изменения только после подтверждения;
- LuCI parity для diagnostics, SNI, Podkop status, Amnezia clients и QoS;
- Podkop health после reboot через связку `podkop status`, процесс `sing-box`, nft/routing rules, sing-box config, DNS и реальную связность.

Что осталось:

- прогнать diagnostics на живом Podkop после fresh install;
- проверить emergency DNS fallback;
- проверить SNI checker read-only flow;
- проверить SNI apply flow: backup, update VPS inbound, update report, update Podkop;
- убедиться, что `podkop status`, `sing-box`, nft/routing rules, DNS и реальная связность согласованы;
- проверить, что LuCI и shell показывают одинаковый статус.

Telegram bot не блокирует milestone: сервис ставится и стартует, но live Telegram API зависит от доступности Telegram с маршрута роутера.

Дополнения (добавлены по результатам архитектурного анализа):

- интегрировать `tools/wg-vless-chain-diagnostics.sh` как подпункт диагностики или `warren remote diag`; сейчас инструмент доступен только тем, кто знает о директории `tools/`;
- добавить JSON-строку результата прогона диагностики (`timestamp`, `mode`, `ok_count`, `warn_count`, `bad_count`, `last_error`) в конец лог-файла, чтобы можно было быстро агрегировать историю без чтения всего лога;
- добавить режим быстрой проверки `diagnostics --quick`: только active checks без полного snapshot (время, podkop runtime, proxy TCP), завершается за 10–15 секунд.

### Milestone 7 — Remote Admin

Статус: `implemented`, требуется стабилизация.

Уже реализовано:

- Mac хранит VPS profiles локально и запускает `warren remote`;
- VPS держит helper и каталог роутеров;
- роутер поднимает on-demand reverse tunnel и отвечает на polling;
- LuCI и SSH доступны через localhost forwards.

Что осталось:

- добить VPS Reality provisioning resilience;
- закрепить `3x-ui` version pin и API fallback;
- прогнать hardware E2E на fresh VPS: `3x-ui`, VLESS Reality, Warren report, `warren-remote`;
- прогнать автоматизированный router agent install на чистом OpenWrt;
- проверить polling `300s` и кнопку `Проверить сейчас`;
- стабилизировать автоматизированный Mac flow: list routers, request, tunnel, SSH/LuCI probes, close;
- убедиться, что после `auto`-прогона `warren` снова показывает меню;
- довести unattended daemon heartbeat и статусы `status/list`.

Дополнения (добавлены по результатам архитектурного анализа):

- добавить rotation по нескольким VPS endpoints в Remote Admin polling: если основной VPS недоступен, агент пробует следующий из списка `REMOTE_ADMIN_ENDPOINTS`; это уже поддержано конфигом, нужно убедиться, что fallback в агенте действительно работает и покрыт regression;
- добавить индикатор статуса Remote Admin в LuCI sidebar (подключён / ожидает / недоступен) без отдельного запроса; достаточно читать локальный state file агента.

### Milestone 8 — Self SNI

Статус: `design + implementation needed`.

Что осталось:

- оформить отдельный shell/LuCI сценарий `Self SNI`;
- решить, где выполняется проверка: router, VPS или оба;
- определить, только ли сценарий рекомендует значения или также применяет их;
- связать результат с существующим SNI report;
- добавить безопасный apply в Podkop/`3x-ui`;
- добавить rollback backup.

### Milestone 9 — Shadowsocks Fallback

Статус: `WIP placeholder`.

Что осталось:

- определить формат fallback report;
- добавить установку/настройку Shadowsocks на VPS;
- добавить Podkop backup channel apply;
- добавить LuCI card/status.

Пока milestone не начат, shell и LuCI показывают только placeholder и не меняют состояние роутера.

### Milestone 10 — RF Bundle

Статус: `WIP placeholder`.

Цель milestone — установка Warren без GitHub, OpenWrt downloads и других внешних
remote services во время install, если доступен заранее подготовленный
РФ-доступный mirror. Основной источник для первого варианта — Yandex mirror.

Архитектура:

- минимальный RF launcher:
  - POSIX shell, только код, нужный до `expand-root` и его выполнения;
  - скачивает RF catalog, проверяет SHA256, определяет OpenWrt release,
    package manager, target и arch;
  - скачивает только `base-preexpand` до расширения overlay;
  - сохраняет state и после reboot продолжает post-expand установку;
- RF catalog/manifest:
  - содержит версию Warren, supported targets, список bundles, размеры,
    sha256, зависимости и install order;
  - URL должны быть прямыми HTTP download links, совместимыми с BusyBox `wget`;
  - если Yandex Disk не даёт стабильную прямую ссылку, использовать Yandex
    Object Storage или другой РФ-доступный direct-download mirror;
- модульные архивы вместо одного большого bundle:
  - `base-preexpand` — только пакеты и скрипты, нужные для preflight,
    проверки времени/package manager и `expand-root`;
  - `base-postexpand` — полный базовый набор Warren после расширения overlay;
  - `warren-core` — `warren.sh`, `lib`, `assets`, `VERSION`, LuCI runtime files;
  - `podkop` — pinned Podkop installer и его offline dependencies;
  - `amneziawg` — `kmod-amneziawg`, `amneziawg-tools`, LuCI protocol/app
    packages строго под OpenWrt release, kernel, target и arch;
  - optional bundles: `luci`, `tg-bot`, `remote-admin`, `sni-checker`,
    `diagnostics`;
  - `vps` — VPS-side offline bundle для `3x-ui` installer/assets и Warren VPS
    helper без GitHub raw.

Первый supported scope:

- NanoPi R5S/R5C;
- OpenWrt `24.10.x` через `opkg`/`.ipk`;
- OpenWrt `25.12.x` через `apk`/`.apk`;
- router-side и VPS-side offline bundles.

Правила install flow:

- пункт `99` остаётся безопасным: если RF catalog или подходящий bundle не
  выбран/не найден, Warren только показывает ошибку и ничего не меняет;
- RF mode не ходит в GitHub/OpenWrt/GitHub releases, если нужные artifacts есть
  в mirror;
- если bundle не подходит под текущие OpenWrt release, package manager,
  target/arch или AWG kernel ABI, установка останавливается до изменений;
- большие компоненты скачиваются только после успешного `expand-root` и reboot.

Acceptance checks:

- fresh install на R5S/R5C OpenWrt `24.10.x`: pre-expand, reboot,
  post-expand, Warren menu;
- fresh install на R5S/R5C OpenWrt `25.12.x`: pre-expand, reboot,
  post-expand, Warren menu;
- отказ на неверный arch/target/kernel для AmneziaWG;
- отказ на повреждённый bundle или SHA256 mismatch до установки;
- resume после reboot продолжает RF flow, а не начинает заново;
- Podkop, AmneziaWG и VPS setup устанавливаются без GitHub/raw external fetch.

### Milestone 11 — USB Modem

Статус: `WIP placeholder`.

Что осталось:

- detect modem: USB device, network interface, uqmi/mbim/ppp availability;
- режимы: primary uplink или backup uplink;
- UCI network/firewall setup;
- status/diagnostics в shell и LuCI;
- rollback к обычному WAN.

Пока milestone не начат, shell и LuCI показывают только placeholder и не меняют состояние роутера.

### Milestone 12 — NaiveProxy

Статус: `WIP placeholder`.

Что осталось:

- отдельный сценарий настройки NaiveProxy на VPS;
- генерация client config/report;
- интеграция с Podkop как отдельный proxy source;
- LuCI card/status.

### Milestone 13 — Monitoring

Статус: `planned`.

Финальное решение:

- `luci-app-nlbwmon` остаётся для traffic per client;
- `luci-app-statistics` остаётся для общей системной статистики;
- NetData не включается в базовый install по умолчанию.

Что осталось:

- проверить `opkg` на `24.x` и `apk` на `25.x`;
- проверить enable hooks для `nlbwmon` и `collectd`;
- обновить roadmap и UI так, чтобы они ссылались на эту схему, а не на NetData.

### Milestone 14 — Version Pinning

Статус: `done` для `25.x` — hardware E2E 2026-09-25: fresh `25.12.5`, exact AWG release, Podkop `0.7.21`, 3x-ui `v3.5.0`, `40 PASS / 0 FAIL`. Fallback path AWG покрыт unit-тестами (same-kernel правило).

Сделано:

- policy по критичным зависимостям держится в `lib/versions.sh`;
- не пинятся все OpenWrt-пакеты: поддерживаются семейства `24.x` через `opkg` и `25.x` через `apk`;
- проверенный совместимый комплект: OpenWrt/AWG `25.12.5`, Podkop `0.7.21`, 3x-ui `v3.5.0`;
- hardware E2E устанавливает exact AWG packages и проверяет kernel module, `awg` keygen и netifd protocol, но не создаёт `awg0` и не меняет маршруты;
- пинятся `3x-ui`, Podkop installer, Warren bundle и Remote Admin protocol как компоненты, которые могут сломать API/CLI/протокол;
- не пинятся зависимости, которые ставит сам Podkop, но проверяется поведение `sing-box`/`xray` в diagnostics;
- для AmneziaWG используется источник `Slava-Shchipunov/awg-openwrt`, потому что `kmod-amneziawg` зависит от exact OpenWrt/kernel/target build;
- для AmneziaWG сначала ищется exact release `v${DISTRIB_RELEASE}`, а если его нет — предлагается nearest same-family fallback в shell и автоматически пробуется fallback из LuCI;
- force-install для AWG fallback не используется.

Что осталось проверить:

- fresh install на OpenWrt `25.12.x` через `apk` (`24.10.x` не тестируется);
- exact AmneziaWG release path;
- fallback AmneziaWG release path;
- diagnostics report на живом роутере с Podkop, AmneziaWG и VPS.

Что это даёт:

- одинаковое поведение на fresh install и на повторной установке;
- меньше регрессий из-за API/CLI несовместимости upstream;
- явный контроль над тем, какие именно версии считаются tested and supported;
- безопасный AWG fallback без смешивания пакетов разных OpenWrt-семейств.

### Milestone 15 — Network Resilience & Download Integrity

Статус: `done`.

Цель milestone — сделать сетевые операции Warren устойчивыми к временным сбоям и проверяемыми по целостности. Особенно важно для пользователей из РФ, где CDN и raw.githubusercontent.com периодически недоступны.

Retry/backoff:

- `warren_wget_retry url out [expected_sha [label]]` добавлен в `lib/common.sh`;
- стратегия: 3 попытки с задержками 0s, 5s, 15s;
- при исчерпании попыток — `fail` с понятным сообщением;
- retry добавлен в `download_file`, `fetch_lib`, `fetch_asset`, `warren_install_bootstrap_file` и самообновление;
- bootstrap и runtime используют одну семантику backoff; симуляция сетевого сбоя покрыта regression test.

SHA256 manifest для Warren-файлов:

- `SUMS.txt` находится рядом с `VERSION`; формат: `sha256  filename`;
- `tools/update-sums.sh` атомарно обновляет manifest и `SUMS_SHA256` в `VERSION`, `--check` ловит stale manifest;
- lib-файлы, assets, LuCI payload, bootstrap и самообновление проверяют SHA256 до замены;
- при mismatch скачанный файл удаляется и Warren падает с явным сообщением;
- `WARREN_SKIP_HASH_CHECK=1` позволяет обойти manifest только в dev-режиме.

Acceptance:

- симуляция временного обрыва сети: Warren повторяет попытку и продолжает установку;
- подмена lib-файла в download: Warren обнаруживает несоответствие SHA256 и останавливается;
- dev-режим с `WARREN_SKIP_HASH_CHECK=1` проходит без manifest;
- самообновление проверяет SHA256 перед заменой `warren.sh`.

Live regression: OpenWrt `25.12.5`, persistent manifest и 18 runtime payload-файлов проверены на R5S; короткий E2E после установки — `35 PASS / 0 FAIL`.

### Milestone 16 — Security Hardening

Статус: `done`.

Цель milestone — устранить архитектурные уязвимости, которые существуют независимо от того, что Warren работает с root-правами.

Реализовано:

- `load_conf_if_exists` читает только whitelist ключей и не source-ит конфиг;
- `save_conf` сохраняет backward-compatible shell-quoted формат;
- `conf_set` присваивает только явно поддержанные ключи через `case`;
- `ask()` использует `warren_set_var` без `eval`;
- после успешного VPS setup `VPS_ROOT_PASSWORD` очищается в `warren.conf` и runtime state;
- приватный VPS report остаётся с правами `0600` и содержит recovery copy плюс пояснение об очистке конфига;
- `log()` полностью маскирует сообщения, содержащие `PASSWORD`, `TOKEN` или `SECRET`.

Acceptance:

- файл `warren.conf` с дополнительными shell-командами не приводит к их выполнению при load_conf;
- `VPS_ROOT_PASSWORD` отсутствует в `warren.conf` после завершения VPS setup;
- `warren.log` не содержит plaintext паролей или токенов;
- `warren.conf` с предыдущими версиями читается корректно.

Live regression: на R5S подтверждены `report=0600`, очистка пароля из рабочего конфига, redaction лога и отсутствие исполнения command-like строки; полный короткий E2E после изменений — `35 PASS / 0 FAIL`.

### Milestone 17 — Podkop Watchdog

Статус: `implemented`, core live regression пройден.

Цель milestone — обеспечить автоматическое восстановление Podkop/sing-box после сбоя без участия пользователя.

Реализовано:

- отдельный procd service `/etc/init.d/warren-watchdog` и worker `/usr/libexec/warren/warren-watchdog`;
- loop с `WARREN_WATCHDOG_INTERVAL` (default `60s`);
- engine определяется точно через `/proc/<pid>/comm`, потому что BusyBox `pgrep -x` дал false negative на живом R5S;
- health требует `sing-box` и активные policy rules Podkop;
- restart delay, ограниченные ступени backoff `60s`, `120s`, `300s`, затем состояние `exhausted`;
- стабильное окно `WARREN_WATCHDOG_STABLE_WINDOW` (default `600s`) сбрасывает счётчики;
- состояние атомарно хранится в `/etc/warren/warren-watchdog.state`.

Уведомления:

- если настроен Telegram-бот, watchdog отправляет сообщение при перезапуске Podkop;
- формат: `[Warren Watchdog] Podkop перезапущен на <hostname> в <time>. Причина: sing-box не найден.`
- при исчерпании попыток: уведомление с пометкой «требуется ручное вмешательство».

Управление:

- `warren --watchdog status|enable|disable|reset|run-once`;
- LuCI card показывает installed/enabled/running/state, restart/failure counters и последнюю причину;
- LuCI кнопки: включить, выключить, сбросить счётчик;
- Watchdog включается автоматически после успешной настройки Podkop в `auto`/`podkop_setup`.

Acceptance:

- при kill sing-box watchdog его перезапускает в течение `WARREN_WATCHDOG_INTERVAL * 2` секунд;
- после 3 быстрых сбоев подряд watchdog переходит в backoff и не перезапускает бесконечно;
- Telegram-уведомление о перезапуске приходит если бот настроен;
- watchdog выживает после reboot роутера;
- `warren --watchdog status` корректно показывает состояние из shell и LuCI.

Live regression на R5S/OpenWrt `25.12.5`:

- точный PID `sing-box` завершён контролируемо;
- Watchdog зафиксировал `sing-box-not-running`, выполнил один Podkop restart и восстановил engine;
- policy rule и foreign HTTPS после восстановления работают;
- после reboot изменился boot ID, Watchdog остался enabled/running, `sing-box`, rules и HTTPS восстановились;
- hardware E2E перед fault injection: `35 PASS / 0 FAIL`.

Не проверено автономно: фактическая доставка Telegram alert, потому что на тестовом роутере нет настроенного bot token/chat.

### Milestone 18 — OpenWrt 26.x+ Graceful Compatibility

Статус: `implemented`, simulation regression пройден.

Цель milestone — Warren не должен категорически отказываться запускаться на семействах `26.x` и выше, которые не существовали при написании кода. Поддержка `24.x` и `25.x` закрыта Milestone 4.

Реализовано:

- для major release `26` и выше family помечается `unknown/graceful`;
- Warren выводит `WARN` и предлагает явное подтверждение;
- package manager определяется эвристически (`apk`, затем `opkg`);
- diagnostics VERSION POLICY помечает такой релиз как `unknown/graceful`;
- `WARREN_ALLOW_UNKNOWN_OPENWRT=1` убирает prompt для CI/автоматических прогонов.

AmneziaWG:

- exact/fallback resolver получает реальный release и package manager;
- отсутствие exact/fallback packages завершается явной ошибкой с release/arch/target, без force-install.

Acceptance:

- Warren запускается на условном `26.01.0` с предупреждением, но без краша;
- при `WARREN_ALLOW_UNKNOWN_OPENWRT=1` нет интерактивного prompt;
- diagnostics отчёт содержит корректный VERSION POLICY блок для `26.x`;
- `24.x` и `25.x` не затронуты (покрыты Milestone 4).

Regression:

- POSIX tests покрывают `26.01.0`, будущий `30.2.1` и noninteractive flag;
- аппаратная регрессия остаётся на поддерживаемом R5S/OpenWrt `25.12.5`;
- фактический `26.x` image пока не существует в тестовом наборе, поэтому hardware validation graceful path будет добавлен после выхода такого релиза.
