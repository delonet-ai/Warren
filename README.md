# Warren

![Warren logo](assets/warren-logo.svg)

🇷🇺 **Русский ** • 🇬🇧 **English below**

Русская версия для пользователя находится ниже на этой странице.  
English version is also available below: see [English](#english).

## Русская версия

### Что это
`Warren` это удобный установщик и помощник для роутеров на OpenWrt, в первую очередь для NanoPi R5S/R5C.

Проект нужен, чтобы с минимальным количеством ручных действий:
- подготовить OpenWrt,
- настроить Podkop,
- подготовить VPS под `VLESS + Reality`,
- поднять приватный доступ через `AmneziaWG`,
- позже управлять клиентами, QoS и удалённым администрированием.

Идея простая: пользователь заходит по SSH на роутер, запускает одну команду и дальше работает через понятное меню.

### Для кого это
Проект ориентирован на тех, кто не хочет:
- ставить Homebrew, Python и дополнительные утилиты на компьютер,
- вручную конфигурировать VPS и роутер по десяткам инструкций,
- каждый раз вспоминать команды OpenWrt, AmneziaWG, firewall и UCI.

### Что уже есть сейчас
Текущий скрипт уже умеет:
- проверять OpenWrt, интернет и время,
- устанавливать базовые пакеты,
- расширять `overlay` через `expand-root`,
- ставить и настраивать Podkop,
- поднимать приватный туннель,
- управлять клиентами приватного доступа.
- ставить Telegram-бота на OpenWrt для быстрых правок Podkop.
- проверять SNI-кандидаты для `VLESS + Reality` на стороне VPS без изменения `3x-ui` и firewall.

Сейчас Warren рассчитан на OpenWrt `24.10.x` и `25.12.x`.
Базовые сценарии, Podkop/LuCI/TG-бот и Amnezia-first поток должны работать из одной кодовой базы: `24.10.x` через `opkg`, `25.12.x` через `apk`.

### Что планируется
В проекте будет главное меню с такими режимами:
- `Автоматический режим`
- `Basic setup`
- `Настрой мне VPS`
- `Podkop`
- `Доустановить Amnezia в Podkop`
- `QoS для Amnezia`
- `Управление Amnezia клиентами`
- `Remote Admin` (`WIP, Milestone 9`)
- `USB модем настрой` (`WIP, Milestone 11`)
- `Telegram-бот для Podkop`
- `Диагностика Podkop/VPS`
- `Проверка SNI-кандидатов Reality`
- `NaiveProxy` (`WIP, Milestone 12`)
- `Shadowsocks fallback` (`WIP, Milestone 8`)
- `Установить всё из РФ сегмента` (`WIP, Milestone 10`)

### Где Warren хранит данные

Постоянные данные Warren на роутере теперь лежат в двух каталогах:
- `/etc/warren` — конфиги, state и VPS-отчёты,
- `/root/warren` — логи и диагностические файлы.

Важные пути:
- VPS-отчёты: `/etc/warren/vps/reports`
- SSH-ключи для VPS: `/etc/warren/vps/keys`
- Диагностика: `/root/warren/warren-diagnostics`
- SNI-кандидаты на роутере: `/etc/warren/sni-checker/sni-candidates.txt`
- SNI-отчёты на роутере: `/etc/warren/sni-checker/reports`

### Telegram-бот для Podkop

Скрипт умеет поставить на OpenWrt сервис `warren-tg-bot`. Он спрашивает токен бота от BotFather, опционально `chat_id`, ставит зависимости `curl` и `jq`, создаёт `/usr/bin/warren-tg-bot` и включает `/etc/init.d/warren-tg-bot`.

Основное управление идёт через кнопки:
- `Добавить в black` — бот попросит домен и добавит его в список проксирования.
- `Добавить в white` — бот попросит домен и добавит его в список исключений.
- `IP без VPN` — управление `Routing Excluded IPs`: такие клиенты исключаются из маршрутизации через Podkop.
- `IP только с VPN` — управление `Fully Routed IPs`: весь трафик таких клиентов принудительно идёт через выбранную секцию.
- `Выбор Endpoint` — кнопка `Auto` включает URLTest по всем сохранённым endpoints, ниже идут кнопки с IP/host текущих endpoints.
- `Редактор Endpoint` — добавление и удаление endpoints.
- При добавлении endpoint бот предлагает новые VPS-отчёты из `/etc/warren/vps/reports`, которые создаёт режим `Настрой мне VPS`, или кнопку `Ввести свой`.
- В IP-разделах кнопка с IP удаляет его из списка, а `Добавить новый` переводит бота в режим ввода IP или подсети одной строкой.
- `Статус` показывает оба IP-списка: `IP без VPN` и `IP только с VPN`.
- `Amnezia клиенты` — список, создание, QR/config и удаление AmneziaWG-клиентов.

Текстовые команды тоже остаются:
- `/black example.com` — добавить домен в пользовательский список `podkop.main.user_domains`, то есть в список проксирования.
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

### Диагностика Podkop/VPS

Пункт `11) Диагностика Podkop/VPS` снимает полный диагностический лог на роутере и показывает короткую сводку пользователю.

Проверяется:
- базовая связность WAN и публичных IP,
- локальный и внешний DNS,
- статус `podkop` и `sing-box`/`xray`,
- доступность VLESS endpoint по ping и TCP-порту,
- SSH-порт VPS, если известен `VPS_HOST`, иначе SSH-порт на host из VLESS,
- маршруты, policy rules, слушающие порты, релевантные `nft`-правила и логи.

Если проверка нашла проблемы, скрипт предлагает применить диагностический DNS-fallback для Podkop: `udp` DNS через `77.88.8.8`, затем перезапускает только Podkop и повторяет диагностику. После повторной проверки DNS-настройки Podkop возвращаются как были до диагностики, Podkop перезапускается ещё раз. Оба снимка и шаг восстановления сохраняются в один файл `/root/warren/warren-diagnostics/warren-diagnostics-*.log`.

### Проверка SNI-кандидатов Reality

Пункт `12) Проверка SNI-кандидатов Reality` берёт список доменов из `assets/sni-candidates.txt`, копирует его на роутер в `/etc/warren/sni-checker/sni-candidates.txt`, а затем на выбранный VPS в `/root/sni-checker/`.

Проверка на VPS:
- показывает hostname, OS, public IP, `ss -tulpn` и снимок firewall,
- не перезапускает `3x-ui` или `xray`,
- не меняет конфиги, порты и правила firewall,
- проверяет DNS, TCP `443`, TLS `1.3`, verify code, ALPN `h2`, HTTP/2 и время ответа,
- сохраняет отчёты в `txt` и `csv`,
- в конце предлагает лучший SNI-кандидат для `dest`, `serverNames` и клиентского `sni`.

### Как будет работать автоматический режим
`Автоматический режим` должен стать основным сценарием.

Он будет:
1. Сразу спрашивать все нужные данные.
2. Сам выполнять базовую настройку роутера.
3. Сам настраивать VPS.
4. Сам подключать Podkop.
5. Сохранять результат в лог.
6. Показывать пользователю важные данные от `3x-ui` и подключения.

Клиент VLESS в `3x-ui` получает имя по IP/host VPS, чтобы в интерфейсе было понятно, к какому серверу относится запись.

### Как запустить

```sh
wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh
```

### Текущее направление проекта
- Центром всей логики будет `OpenWrt`.
- Основной язык проекта: `sh`.
- Для приватного доступа делаем ставку на `AmneziaWG`.
- WIP-направления вынесены в отдельные milestones и не блокируют текущую проверку Amnezia/QoS.

### Roadmap milestones

#### Milestone 5 — Amnezia + QoS Live
Status: `done in 0.6.0`.

Acceptance:
- AmneziaWG ставится на `24.10.x` и `25.12.x`;
- создание, список, config/QR и удаление клиентов работают из shell и LuCI;
- QoS-профили `standard`, `priority`, `bulk`, `limit_1mbit`, `limit_10mbit`, `off` применяются через `nft`;
- QoS восстанавливается после reboot.

#### Milestone 6 — Diagnostics, SNI Checker, LuCI Parity
Рабочие tools без будущих WIP-функций:
- `Diagnostics Podkop/VPS`;
- emergency DNS-fallback;
- VPS-side `SNI checker`;
- LuCI parity для diagnostics, SNI, Podkop status, Amnezia clients и QoS;
- Podkop health после reboot: не полагаться только на `/etc/init.d/podkop status`, а проверять связку `podkop status`, процесс `sing-box`, nft/routing rules, sing-box config, DNS и реальную связность. На `24.10.x` был пойман случай, где `sing-box` и трафик живы, но init-status показывает `not running`.

Telegram bot не блокирует этот milestone: сервис ставится и стартует, но live Telegram API зависит от доступности Telegram с маршрута роутера.

#### Milestone 7 — Self SNI
Отдельный будущий дизайн для самостоятельной проверки/подбора SNI. До реализации нужно зафиксировать, где выполняется проверка, меняет ли она конфиг автоматически и как результат попадает в Podkop/3x-ui.

#### Milestone 8 — Shadowsocks Fallback
Будущий fallback-сценарий на Shadowsocks. Сейчас shell и LuCI показывают только WIP-placeholder и ничего не меняют.

#### Milestone 9 — Remote Admin
Будущий безопасный удалённый доступ к роутеру. Сейчас это WIP-placeholder.

#### Milestone 10 — RF Bundle
Будущая установка Warren из локального bundle или другого доступного ресурса внутри РФ-сегмента. Сейчас пункт `99` ничего не меняет.

#### Milestone 11 — USB Modem
Будущие сценарии USB-модема как основного или резервного uplink. Сейчас это WIP-placeholder.

#### Milestone 12 — NaiveProxy
Будущий отдельный сценарий настройки NaiveProxy. Сейчас это WIP-placeholder.

---

## English

### What it is
`Warren` is a guided OpenWrt setup project for NanoPi R5S/R5C routers.

Its goal is to make router and VPS setup much easier from a single SSH session on OpenWrt.

The project is intended to help users:
- prepare a clean OpenWrt system,
- configure Podkop,
- provision a VPS for `VLESS + Reality`,
- set up private remote access with `AmneziaWG`,
- later manage clients, QoS, and remote administration features.

### Who it is for
This project is for users who want a simple, guided setup flow and do not want to install extra tooling on their local machine.

The intended experience is:
1. SSH into the router.
2. Run one install command.
3. Follow a friendly on-screen menu.

### Current status
The repository already contains a working bootstrap script and is evolving into a broader orchestration system for:
- router preparation,
- VPS setup,
- Podkop configuration,
- private remote access,
- future client/QoS/admin workflows.

### Installation

```sh
wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh
```

---

## Technical Overview

### Product Direction

The router on OpenWrt is the center of orchestration.

Why this approach:
- the user only needs SSH access to OpenWrt,
- no Homebrew, Python, or local tooling on macOS/Windows/Linux is required,
- one entrypoint is easier for non-technical users,
- the router can configure both itself and the remote VPS.

The project stays on `sh` and is intended to be modularized into multiple shell libraries rather than migrated wholesale to Python.

### User Journey

#### Install flow
1. The user connects to OpenWrt over SSH.
2. The user runs a single install command.
3. The script clears terminal noise, shows a welcome screen, and opens the main menu.
4. The user chooses either a guided full flow or a focused mode for a specific task.

#### Main menu target design
- `Automatic mode`
  Runs the full guided flow except client creation for AmneziaWG.
- `Basic setup`
  Installs packages and prepares the OpenWrt base system.
- `Configure my VPS`
  Connects to the VPS and configures the VLESS + Reality side.
- `Podkop`
  Installs and configures Podkop on OpenWrt.
- `Add Amnezia to existing Podkop`
  Extends an already configured Podkop setup with private AmneziaWG access.
- `QoS for Amnezia`
  Applies per-client DSCP profiles through `nft`.
- `Manage Amnezia clients`
  Create, list, show config/QR, revoke, and remove clients.
- `Remote Admin`
  Work in progress placeholder for Milestone 9.
- `USB modem setup`
  Work in progress placeholder for Milestone 11.

### Automatic Mode

`Automatic mode` is intended to be the main happy-path experience.

It should:
1. Collect all required inputs at the start.
2. Save them to a temporary JSON state file for the duration of the run.
3. Run:
   - `Basic setup`
   - `Configure my VPS`
   - `Podkop`
4. Print and save the resulting VPS/3x-ui access data for the user.
5. Remove the temporary JSON file at the end.

#### Expected inputs for automatic mode
- OpenWrt-side choices:
  - whether to expand root,
  - preset selection,
  - Podkop options,
  - future QoS defaults.
- VPS-side inputs:
  - VPS IP,
  - root password,
  - optional SSH port,
  - optional preferred domain/SNI/public host values for Reality.

#### Output expectations
- concise on-screen summary,
- persisted log file,
- explicit display of:
  - 3x-ui login,
  - 3x-ui password,
  - important connection parameters,
  - generated VLESS string or equivalent import data.

### Functional Areas

#### 1. OpenWrt base preparation
This is the current foundation and already exists in the repository in working form:
- package installation,
- overlay/expand-root workflow,
- reboot-safe continuation,
- basic preparation for Podkop and private tunnel services.

#### 2. VPS provisioning
Planned behavior:
- connect from OpenWrt to a remote VPS,
- install required tools,
- install and configure `3x-ui`,
- configure `VLESS + Reality`,
- return the generated connection details back to OpenWrt.

Important implementation note:
- the first iteration may use password-based SSH login,
- but the flow should aim to transition to key-based access as early as possible.

#### 3. Podkop configuration
Current and planned behavior:
- install Podkop,
- configure VLESS import data,
- enable selected community lists / presets,
- later support curated preset profiles rather than only raw toggles.

#### 4. AmneziaWG private access
The project direction is to prefer `AmneziaWG` for private remote access.

Current behavior:
- install and configure AmneziaWG server on OpenWrt,
- integrate firewall/network rules,
- issue client configs,
- show QR where applicable,
- support revoke/delete/list flows.
- support `24.10.x`/`opkg` and `25.12.x`/`apk` package install paths from the same flow.

#### 5. QoS for Amnezia clients
Current v1 behavior:
- manage per-client profiles: `standard`, `priority`, `bulk`, `limit_1mbit`, `limit_10mbit`, `off`,
- store assignments in `/etc/warren/amnezia-qos.tsv`,
- apply DSCP marking and fixed 1/10 Mbps nft-limit profiles through an `inet warren_qos` nft table,
- reinstall rules after reboot through `/etc/init.d/warren-qos`.

#### 6. Milestone 6 — Diagnostics, SNI Checker, LuCI Parity
Current next milestone after Amnezia/QoS live validation.

Target behavior:
- validate Podkop/VPS diagnostics and emergency DNS fallback,
- validate VPS-side SNI checker reports,
- keep LuCI behavior aligned with shell flows for diagnostics, SNI, Podkop status, Amnezia clients, and QoS,
- make Podkop health checks truthful after reboot by comparing init status with `sing-box`, nft/routing state, generated config, DNS, and real connectivity.

Telegram bot does not block this milestone: the service can be installed and started, but live Telegram API access depends on router-side reachability to Telegram.

#### 7. Self SNI
Status: `WIP`

Target idea:
- design a standalone SNI selection/checking scenario,
- decide whether it runs on the router, VPS, or both,
- decide whether it only recommends values or also applies them.

This area needs a separate design pass before implementation.

#### 8. Shadowsocks fallback
Status: `WIP`

Target idea:
- add Shadowsocks as a fallback strategy separate from the current VLESS-based Podkop path.

Until Milestone 8 starts, shell and LuCI only show placeholders and do not change router state.

#### 9. Remote Admin
Status: `WIP`

Target idea:
- enable the maintainer to reach both OpenWrt and VPS remotely,
- work even when the router has no public external IP,
- account for USB modem / cellular scenarios,
- likely depend on an outbound tunnel model rather than inbound access to the router.

This area needs a separate design pass before implementation.

#### 10. RF bundle
Status: `WIP`

Target idea:
- install Warren from a local bundle or another RF-segment reachable source,
- avoid relying on GitHub raw when that path is unavailable.

Until Milestone 10 starts, menu item `99` only shows a placeholder and does not change router state.

#### 11. USB modem setup
Status: `WIP`

Target idea:
- prepare the system for using a USB modem as the main channel,
- prepare the system for using a USB modem as a backup uplink,
- integrate with remote admin and tunnel persistence where possible.

Until Milestone 11 starts, shell and LuCI only show placeholders and do not change router state.

#### 12. NaiveProxy
Status: `WIP`

Target idea:
- add a separate NaiveProxy setup scenario.

Until Milestone 12 starts, shell and LuCI only show placeholders and do not change router state.

### Current State In Repository

The current `warren.sh` and modular `lib/*.sh` layout already cover the first stage of the project refactor.

### Architecture Direction

The codebase should move from one large script to a modular shell layout.

Target structure:

```text
warren.sh
bootstrap.sh
lib/common.sh
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

#### Module responsibilities
- `warren.sh`
  Main entry point and orchestrator.
- `bootstrap.sh`
  Backward-compatible wrapper.
- `lib/common.sh`
  Logging, retries, helpers, command wrappers.
- `lib/ui.sh`
  Banner, terminal reset/clear, prompts, menus, summaries.
- `lib/state.sh`
  State files, temporary JSON payload, cleanup, resume logic.
- `lib/basic.sh`
  Base OpenWrt preparation and package logic.
- `lib/podkop.sh`
  Podkop install/config integration.
- `lib/vps.sh`
  Remote VPS connection, probing, setup, and generated config extraction.
- `lib/amnezia.sh`
  Amnezia Private orchestration.
- `lib/amneziawg.sh`
  AmneziaWG install, server setup, and console client management.
- `lib/tg_bot.sh`
  Telegram control bot for Podkop and AmneziaWG clients.
- `lib/qos.sh`
  Traffic shaping and policy profiles.
- `lib/remote_admin.sh`
  Placeholder module for future remote admin flows.
- `lib/usb_modem.sh`
  Placeholder module for modem-related flows.

### State And Safety

The project should remain reboot-safe and resumable.

Planned state layers:
- persistent step/state marker for resumable operations,
- persistent config only where the user expects installed settings to remain,
- temporary JSON file for one-shot guided flows,
- cleanup of sensitive temporary data after success or explicit abort.

Sensitive data rules:
- never keep VPS root password longer than needed,
- prefer upgrading to SSH key auth,
- scrub temporary files on success and on controlled failure paths where possible.

### Roadmap Snapshot

Near-term:
- close Milestone 6 diagnostics, SNI checker, Podkop health, and LuCI parity checks.

Later:
- Milestone 7: Self SNI,
- Milestone 8: Shadowsocks fallback,
- Milestone 9: Remote Admin,
- Milestone 10: RF bundle,
- Milestone 11: USB modem,
- Milestone 12: NaiveProxy.
