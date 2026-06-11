# Warren: технический README

Этот документ хранит технические детали проекта, milestones разработки, политику версий и внутренние сценарии проверки. Основной пользовательский обзор находится в [README.md](README.md).

## Направление проекта

Центр оркестрации — роутер на OpenWrt. Пользователь должен иметь возможность зайти на роутер по SSH, запустить один entrypoint и дальше выполнить настройку роутера, Podkop, VPS, AmneziaWG, QoS, Telegram-бота, диагностики и Remote Admin из меню Warren.

Проект остаётся на `sh` и развивается в сторону модульной структуры вместо одного большого скрипта.

Поддерживаемые семейства OpenWrt:

- OpenWrt `24.10.x` — ожидается `opkg`;
- OpenWrt `25.12.x` — ожидается `apk`.

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

## Управление версиями и зависимостями

Warren не пинит все OpenWrt-пакеты. Большинство пакетов (`curl`, `wget`, `ca-certificates`, `qrencode`, `tcpdump`, LuCI runtime и другие) должны ставиться штатным пакетным менеджером текущего OpenWrt.

Критичные компоненты:

- `Podkop installer` — Warren пинит URL installer на release tag, но не управляет зависимостями Podkop.
- `3x-ui` — Warren пинит release tag, потому что setup зависит от API, путей панели, SQLite/API token и Reality inbound behavior.
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

Fallback path:

- fallback разрешён только внутри той же OpenWrt family;
- `24.10.x` никогда не fallback-ится на `25.12.x`;
- `25.12.x` никогда не fallback-ится на `24.10.x`;
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
- проверяется соответствие package manager: `24.10.x/opkg`, `25.12.x/apk`.

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
10. Create a test request, wait for polling, and verify reverse tunnel.
11. Open LuCI through localhost forwards.
12. Run `close` and confirm tunnel and request disappear cleanly.
13. Reboot the router and verify base state comes back normally.

Pass criteria:

- Empty router bootstraps without manual file edits.
- Empty VPS receives Warren remote components automatically.
- Remote Admin becomes usable only after router/VPS parts are in place.
- `list`, `status`, `request`, and `close` work on the VPS helper.
- Mac-driven Remote Admin can reach router SSH and LuCI through localhost.

## Milestones разработки

Этот раздел является основным источником задач и статусов roadmap.

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
- проверить fresh VPS reinstall: `3x-ui`, VLESS Reality, Warren report, `warren-remote`;
- проверить router agent install на чистом OpenWrt;
- проверить polling `300s` и кнопку `Проверить сейчас`;
- проверить Mac flow: list routers, request, tunnel, open LuCI, close;
- убедиться, что после `auto`-прогона `warren` снова показывает меню;
- довести unattended daemon heartbeat и статусы `status/list`.

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

Что осталось:

- собрать локальный Warren bundle: `warren.sh`, `lib`, `assets`, LuCI files;
- добавить install from local bundle;
- добавить install from РФ-доступного mirror/source;
- оставить пункт `99` безопасным, пока bundle не выбран.

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

Статус: `implemented`, требуется live regression.

Сделано:

- policy по критичным зависимостям держится в `lib/versions.sh`;
- не пинятся все OpenWrt-пакеты: поддерживаются семейства `24.10.x` через `opkg` и `25.12.x` через `apk`;
- пинятся `3x-ui`, Podkop installer, Warren bundle и Remote Admin protocol как компоненты, которые могут сломать API/CLI/протокол;
- не пинятся зависимости, которые ставит сам Podkop, но проверяется поведение `sing-box`/`xray` в diagnostics;
- для AmneziaWG используется источник `Slava-Shchipunov/awg-openwrt`, потому что `kmod-amneziawg` зависит от exact OpenWrt/kernel/target build;
- для AmneziaWG сначала ищется exact release `v${DISTRIB_RELEASE}`, а если его нет — предлагается nearest same-family fallback в shell и автоматически пробуется fallback из LuCI;
- force-install для AWG fallback не используется.

Что осталось проверить:

- fresh install на OpenWrt `24.10.x` через `opkg`;
- fresh install на OpenWrt `25.12.x` через `apk`;
- exact AmneziaWG release path;
- fallback AmneziaWG release path;
- diagnostics report на живом роутере с Podkop, AmneziaWG и VPS.

Что это даёт:

- одинаковое поведение на fresh install и на повторной установке;
- меньше регрессий из-за API/CLI несовместимости upstream;
- явный контроль над тем, какие именно версии считаются tested and supported;
- безопасный AWG fallback без смешивания пакетов разных OpenWrt-семейств.
