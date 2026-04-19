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
- каждый раз вспоминать команды OpenWrt, WireGuard, firewall и UCI.

### Что уже есть сейчас
Текущий скрипт уже умеет:
- проверять OpenWrt, интернет и время,
- устанавливать базовые пакеты,
- расширять `overlay` через `expand-root`,
- ставить и настраивать Podkop,
- поднимать приватный туннель,
- управлять клиентами приватного доступа.
- ставить Telegram-бота на OpenWrt для быстрых правок Podkop.

### Что планируется
В проекте будет главное меню с такими режимами:
- `Автоматический режим`
- `Basic setup`
- `Настрой мне VPS`
- `Podkop`
- `Доустановить Amnezia в Podkop`
- `QoS для Amnezia`
- `Управление Amnezia клиентами`
- `Remote Admin` (`WIP`)
- `USB модем настрой` (`WIP`)
- `Telegram-бот для Podkop`

### Telegram-бот для Podkop

Скрипт умеет поставить на OpenWrt сервис `warren-tg-bot`. Он спрашивает токен бота от BotFather, опционально `chat_id`, ставит зависимости `curl` и `jq`, создаёт `/usr/bin/warren-tg-bot` и включает `/etc/init.d/warren-tg-bot`.

Основное управление идёт через кнопки:
- `Добавить в black` — бот попросит домен и добавит его в список проксирования.
- `Добавить в white` — бот попросит домен и добавит его в список исключений.
- `IP без VPN` — управление `Routing Excluded IPs`: такие клиенты исключаются из маршрутизации через Podkop.
- `IP только с VPN` — управление `Fully Routed IPs`: весь трафик таких клиентов принудительно идёт через выбранную секцию.
- `Выбор Endpoint` — кнопка `Auto` включает URLTest по всем сохранённым endpoints, ниже идут кнопки с IP/host текущих endpoints.
- `Редактор Endpoint` — добавление и удаление endpoints.
- При добавлении endpoint бот предлагает новые VPS-отчёты из `/etc/vps/reports`, которые создаёт режим `Настрой мне VPS`, или кнопку `Ввести свой`.
- В IP-разделах кнопка с IP удаляет его из списка, а `Добавить новый` переводит бота в режим ввода IP или подсети одной строкой.
- `Статус` показывает оба IP-списка: `IP без VPN` и `IP только с VPN`.

Текстовые команды тоже остаются:
- `/black example.com` — добавить домен в пользовательский список `podkop.main.user_domains`, то есть в список проксирования.
- `/white example.com` — добавить домен в секцию `podkop.warren_whitelist` с `connection_type='exclusion'`.
- `/endpoints` — показать сохранённые VLESS/proxy endpoints.
- `/use 1` — переключить `podkop.main` на endpoint по номеру.
- `/add_endpoint vless://...` — добавить endpoint в список бота.
- `/no_vpn 192.168.1.20` — добавить IP в `Routing Excluded IPs`.
- `/vpn_only 192.168.1.30` — добавить IP в `Fully Routed IPs`.
- `/status` — показать короткое состояние.

Если `chat_id` оставить пустым при установке, первый чат, который напишет `/start`, будет автоматически привязан к боту.

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
- `Remote Admin` и работа с USB-модемами будут добавляться отдельными этапами.

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
  Applies client policies, shaping, or prioritization rules.
- `Manage Amnezia clients`
  Create, list, show config/QR, revoke, and remove clients.
- `Remote Admin`
  Work in progress placeholder for remote administration tooling.
- `USB modem setup`
  Work in progress placeholder for mobile uplink / backup uplink scenarios.

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

Planned behavior:
- install and configure AmneziaWG server on OpenWrt,
- integrate firewall/network rules,
- issue client configs,
- show QR where applicable,
- support revoke/delete/list flows.

#### 5. QoS for Amnezia clients
Planned behavior:
- define per-client priorities or profiles,
- optionally apply bandwidth limits,
- later expose policy profiles through UCI/LuCI-compatible config,
- keep initial implementation simple and deterministic.

#### 6. Remote Admin
Status: `WIP`

Target idea:
- enable the maintainer to reach both OpenWrt and VPS remotely,
- work even when the router has no public external IP,
- account for USB modem / cellular scenarios,
- likely depend on an outbound tunnel model rather than inbound access to the router.

This area needs a separate design pass before implementation.

#### 7. USB modem setup
Status: `WIP`

Target idea:
- prepare the system for using a USB modem as the main channel,
- prepare the system for using a USB modem as a backup uplink,
- integrate with remote admin and tunnel persistence where possible.

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
  AmneziaWG server and client management.
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
- finish VPS provisioning for `3x-ui + VLESS + Reality`,
- replace current WireGuard backend with AmneziaWG flows,
- add QoS profiles for private clients,
- expand automatic mode into a full end-to-end setup.

Later:
- remote admin architecture,
- USB modem main/backup uplink flows,
- LuCI/UCI-friendly configuration surfaces where practical.
