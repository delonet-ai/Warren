# Warren

![Warren logo](assets/warren-logo.svg)

`Warren` — установщик и помощник для роутеров на OpenWrt, в первую очередь для NanoPi R5S/R5C.

Проект нужен, чтобы с минимальным количеством ручных действий подготовить роутер, настроить Podkop, подключить VPS с `VLESS + Reality`, поднять приватный доступ через `AmneziaWG` и дальше управлять этим из одного понятного меню.

Основной сценарий: пользователь заходит по SSH на роутер, запускает одну команду и дальше выбирает нужные действия в Warren.

## Для кого

Warren ориентирован на пользователей, которые не хотят вручную собирать настройку из десятков инструкций и каждый раз вспоминать команды OpenWrt, firewall, UCI, Podkop, AmneziaWG и VPS-панели.

Цель проекта — оставить сложность внутри скриптов, а пользователю дать предсказуемый поток:

1. Подключиться к OpenWrt по SSH.
2. Запустить Warren.
3. Пройти базовую настройку, Podkop, VPS и приватный доступ через меню.

## Что уже есть

Текущий Warren умеет:

- проверять OpenWrt, интернет, время и базовую среду;
- устанавливать базовые пакеты;
- расширять `overlay` через `expand-root`;
- устанавливать и настраивать Podkop;
- готовить VPS под `VLESS + Reality`;
- проверять и применять SNI-кандидаты для Reality;
- устанавливать и настраивать `AmneziaWG` на OpenWrt;
- создавать, показывать, удалять и диагностировать клиентов AmneziaWG;
- применять QoS-профили для AmneziaWG-клиентов;
- ставить Telegram-бота для быстрых правок Podkop;
- запускать диагностику Podkop/VPS;
- поднимать Remote Admin для доступа к роутеру через VPS без публичного IP на роутере;
- работать с семейством OpenWrt `24.x` через `opkg` и с семейством `25.x` через `apk`.

## Как запустить

```sh
wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh
```

## Скриншоты TUI

Главное меню Warren:

![Главное меню Warren](assets/screenshots/warren-main-menu.svg)

Подменю Podkop:

![Подменю Podkop](assets/screenshots/warren-podkop-menu.svg)

Управление AmneziaWG-клиентами:

![Управление AmneziaWG-клиентами](assets/screenshots/warren-amnezia-clients.svg)

## Основные режимы

В меню Warren развиваются такие направления:

- `Автоматический режим` — полный сценарий настройки роутера, Podkop, VPS и связанных компонентов.
- `Basic setup` — базовая подготовка OpenWrt.
- `Настрой мне VPS` — установка и настройка VPS под `3x-ui`, `VLESS + Reality` и Warren-отчёты.
- `Podkop` — установка и настройка Podkop.
- `Доустановить Amnezia в Podkop` — добавление приватного доступа через AmneziaWG.
- `QoS для Amnezia` — профили трафика для AmneziaWG-клиентов.
- `Управление Amnezia клиентами` — создание, список, config/QR и удаление клиентов.
- `Telegram-бот для Podkop` — быстрые правки списков, endpoints и клиентов через Telegram.
- `Диагностика Podkop/VPS` — проверка DNS, маршрутов, Podkop, `sing-box`/`xray`, VPS и сетевой связности.
- `Проверка SNI-кандидатов Reality` — безопасная проверка SNI на VPS без изменения конфигов до подтверждения.
- `Remote Admin` — удалённый доступ к OpenWrt через VPS и reverse tunnel.

## Дорожная карта

Ближайшие задачи:

- стабилизировать live regression для AmneziaWG, QoS, diagnostics, SNI checker и LuCI parity;
- довести Remote Admin до устойчивого fresh install flow для чистого OpenWrt и чистого VPS;
- оформить отдельный Self SNI-сценарий;
- добавить fallback-сценарий на Shadowsocks;
- подготовить установку Warren из локального или РФ-доступного bundle;
- добавить сценарии USB-модема как основного или резервного uplink;
- добавить NaiveProxy как отдельный proxy-сценарий;
- закрепить мониторинг через `luci-app-nlbwmon` и `luci-app-statistics`;
- продолжить политику версий для критичных компонентов: Podkop installer, `3x-ui`, AmneziaWG packages, Warren bundle и Remote Admin protocol.

Запланированные улучшения ядра:

- retry/backoff и SHA256 manifest для загрузок и самообновления завершены (Milestone 15);
- безопасный config parser, отказ от `eval`, очистка `VPS_ROOT_PASSWORD` и redaction логов завершены (Milestone 16);
- Podkop Watchdog с procd, ограниченным backoff, shell/LuCI status и опциональным Telegram-уведомлением реализован (Milestone 17);
- graceful degradation для будущих OpenWrt 26.x+ с package-manager detection и CI-флагом реализован (Milestone 18).

Подробная техническая документация, политика зависимостей, внутренние сценарии и milestones разработки находятся в [TECHNICAL_README.md](TECHNICAL_README.md).

## Локальная разработка

Быстрые проверки без роутера и сети:

```sh
sh tools/check.sh
```

Команда проверяет синтаксис shell-файлов, запускает POSIX shell regression tests и собирает временный router-upload bundle.

Firmware, E2E-логи, diagnostics и сгенерированные bundles считаются локальными артефактами и не входят в Git. Создать актуальный upload bundle из текущих исходников:

```sh
sh tools/build-router-upload.sh
```

Для hardware E2E можно скопировать `.env.example` в локальный `.env`; значения из явных CLI-флагов имеют приоритет.

Полный прогон теперь включает настройку и проверку VPS (`3x-ui`, Xray/VLESS Reality, panel, Remote Admin helper/cron), exact AmneziaWG packages с module/keygen self-test без изменения маршрутов, установку router agent и автоматический цикл `request → reverse tunnel → SSH/LuCI через localhost → close`:

```sh
sh tools/test-e2e.sh --fw 25 --vps-host <ip> --vps-pass <password>
```

Если VPS уже настроен, `auto` переиспользует 3x-ui и пересоздаёт inbound. E2E не удаляет существующую установку VPS скрыто: fresh reinstall включается только явным флагом.

Для контролируемой проверки нового pinned 3x-ui E2E поддерживает `--reinstall-3xui`: перед удалением `/etc/x-ui` и Warren VPS artifact сохраняются в `/root/warren-backups/`. Текущий проверяемый комплект — OpenWrt/AWG `25.12.5`, Podkop `0.7.21`, 3x-ui `v3.5.0`.
