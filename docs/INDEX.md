# Warren: карта кода

Навигационный слой для разработки. Здесь только «где что лежит и как связано».
Roadmap и статусы — в [TECHNICAL_README.md](../TECHNICAL_README.md#milestones-разработки),
пользовательский обзор — в [README.md](../README.md), список всех функций — в [SYMBOLS.md](SYMBOLS.md)
(генерируется `sh tools/gen-index.sh`, свежесть проверяет `tools/check.sh`).

## Слои

```text
 Mac (dev/admin)                    Router (OpenWrt 25.x apk, pinned 25.12.5)            VPS (Debian/Ubuntu)
 ─────────────────                  ──────────────────────────────────────────              ───────────────────
 tools/test-e2e.sh ──scp/ssh──▶     bootstrap.sh ─▶ warren.sh (orchestrator)                 3x-ui (pinned v3.5.0)
 tools/remote-admin/                    │  source lib/*.sh (WARREN_LIB_LIST)                  └ VLESS+Reality inbound
   warren-remote-control.sh ─ssh─▶      ├─ interactive menu (lib/ui.sh)                      /usr/local/bin/warren-remote
 tools/wg-vless-chain-                  ├─ LuCI: controller/warren.lua ─▶ warren-luci-run ─▶     (Remote Admin helper)
   diagnostics.sh                       │         warren --luci-run <mode>                   check-sni.sh (SNI checker)
                                        └─ сервисы из payload/ (см. ниже)
```

## Точки входа (`warren.sh: main`)

| Вызов | Что делает |
|---|---|
| `sh warren.sh` / `warren` | `menu` → `MODE` в `warren.conf` → `run_service_mode` или state-flow |
| `warren --luci-run <mode>` | режим из LuCI; форма приходит через env, `luci_apply_form_overrides` |
| `warren --watchdog status\|enable\|disable\|reset\|run-once` | `watchdog_cli` |
| `warren --apply-qos` | `run_qos_apply_only` (вызывается init-скриптом QoS) |
| `warren --install-luci` | `install_warren_luci_ui` |
| `warren remote ...` | exec `tools/remote-admin/warren-remote-control.sh` (Mac-side) |

Порядок в `main`: self-update → разбор CLI → load conf / menu → `run_service_mode` (one-shot, `exit 0`) →
`run_basic_flow` → `run_podkop_flow` → `run_amnezia_private_flow` → summary.

## Режимы (`MODE`)

Режим живёт в `warren.conf` и переживает reboot. Единственный список — `WARREN_MODES` в `lib/modes.sh`
(`mode|menu|kind|target|handler|label`). Из него строятся главное меню и подменю (`lib/ui.sh: menu`,
`warren_submenu`), `run_service_mode` (вызов handler по имени, без `eval`), `mode_target_state`,
`mode_is_one_shot_service` и проверка `warren --luci-run <mode>`. Тесты сверяют реестр с функциями и кнопками LuCI.
Текст-баннеры режимов остаются в `warren.sh: show_mode_banner`.

| Меню | MODE | Тип | Вход | Модуль |
|---|---|---|---|---|
| 0 | `auto` | state-flow → 100 | basic + LuCI + VPS/report + podkop + watchdog | warren.sh |
| 1 | `basic` | state-flow → 75 | `run_basic_flow` | lib/basic.sh |
| 2 | `initialize` | one-shot | `install_warren_luci_ui` | lib/luci.sh |
| 3 | `vps` | one-shot | `run_vps_flow` | lib/vps.sh |
| 4 | `podkop_setup` / `podkop_backup` | state-flow → 95 / one-shot | `run_podkop_flow` / `add_podkop_backup_channel` | lib/podkop.sh |
| 5 | `add_private` | state-flow → 120 | `run_amnezia_private_flow` | lib/amnezia.sh, lib/amneziawg.sh |
| 6 | `qos_private` | one-shot | `run_qos_flow` | lib/qos.sh |
| 7 | `manage_private` | one-shot | `run_amnezia_manage_flow` | lib/amnezia.sh |
| 8 | `remote_admin` | one-shot | `run_remote_admin_flow` | lib/remote_admin.sh |
| 9 | `usb_modem` | one-shot, WIP | `run_usb_modem_flow` | lib/usb_modem.sh |
| 10 | `tg_bot` | one-shot | `run_tg_bot_flow` | lib/tg_bot.sh |
| 11 | `diagnostics` (+`diagnostics_emergency`) | one-shot | `run_diagnostics_flow` / `run_diagnostics_emergency_flow` | lib/diagnostics.sh |
| 12 | `sni_checker` | one-shot | `run_sni_checker_flow` | lib/sni_checker.sh |
| 13 | `sni_apply` | one-shot | `run_sni_apply_flow` | lib/sni_checker.sh |
| 14 | `naiveproxy_wip` | placeholder | `run_naiveproxy_wip_flow` | warren.sh |
| 15 | `shadowsocks_fallback_wip` | placeholder | `run_shadowsocks_fallback_wip_flow` | warren.sh |
| 16 | `remote_admin_console` | Mac-only | exec warren-remote-control.sh | warren.sh |
| 99 | `rf_bundle_wip` | placeholder | `run_rf_bundle_wip_flow` | warren.sh |
| LuCI | `amnezia_client_create/delete`, `remote_admin_config`, `remote_admin_poll_now`, `remote_admin_router_install`, `remote_admin_vps_install`, `watchdog_enable/disable/reset` | one-shot | см. `run_service_mode` | — |

## State machine (`/etc/warren/warren.state`, `lib/state.sh: get_state/set_state`)

| State | Шаг | Где |
|---|---|---|
| 10 / 20 / 30 | `check_openwrt` / `check_inet` / `sync_time` | `run_basic_flow` |
| 35 / 40 | пакеты упали (нет места) / пакеты стоят | `install_full_pkg_list` |
| 45 / 50 | overlay check / expand-root prep | lib/basic.sh, `expand_root_prep` |
| 60 | expand-root выполнен, **reboot** | `expand_root_run_and_reboot` |
| 70 / 75 | повтор пакетов / overlay после reboot — конец `basic` | `run_basic_flow` |
| 80 | Warren LuCI UI установлен (auto) | `ensure_warren_ui_for_auto` |
| 85 | proxy-источник подготовлен (auto: VPS или report) | `prepare_auto_proxy_source` |
| 90 / 95 | Podkop установлен / настроен + watchdog — конец `podkop_setup` | `run_podkop_flow` |
| 100 | конец `auto` / AWG установлен | `print_auto_final_summary` / lib/amnezia.sh |
| 110 / 115 / 120 | AWG server / Podkop патч private iface / клиенты — конец `add_private` | lib/amnezia.sh |

Цели режимов — `mode_target_state`. Номера 100 переиспользуются `auto` и `add_private`
(`run_amnezia_private_flow` сам пересчитывает state по факту: `awg`, `server.key`, UCI proto).

## Данные на роутере

| Путь | Содержимое | Владелец |
|---|---|---|
| `/etc/warren/warren.conf` | `KEY='value'`; читается whitelist-парсером без source | lib/state.sh (`warren_assign_config_key`, `save_conf`, `conf_set`) |
| `/etc/warren/warren.state` | integer state, atomic tmp+mv | lib/state.sh |
| `/etc/warren/vps/{reports,keys}` | VPS reports (0600, содержат доступы), SSH keys | lib/vps.sh |
| `/etc/warren/sni-checker/` | кандидаты, отчёты, backups SNI apply | lib/sni_checker.sh |
| `/etc/warren/warren-tg-bot.conf`, `warren-vless-endpoints` | TG bot config, endpoint store | lib/tg_bot.sh |
| `/etc/warren/warren-watchdog.{conf,state}` | watchdog | lib/watchdog.sh |
| `/root/warren/warren.log`, `warren-diagnostics/` | лог (маскирует PASSWORD/TOKEN/SECRET), диагностика | lib/common.sh, lib/diagnostics.sh |
| `/root/warren/app/` | persistent копия warren.sh + lib + assets | warren.sh (`warren_bootstrap_install_persistent_app`) |
| `/tmp/warren-runtime.{json,tsv}` | runtime state авторежима | lib/state.sh |

Ключи конфига: единственный источник — `warren_assign_config_key` в `lib/state.sh`; LuCI-форма →
env — таблица `allowed` в `write_form_env` (`controller/warren.lua`) → `luci_apply_form_overrides` (`warren.sh`).

## Сервисные скрипты (`payload/`)

Скрипты, которые Warren ставит на роутер или VPS как отдельные процессы. Они **не видят lib/*.sh**.
Установка: `warren_install_payload <name> <target>` (`lib/common.sh`) → источник `$WARREN_PAYLOAD_DIR`
(тесты), checkout `payload/`, `/usr/lib/warren/payload/`, затем download с проверкой SHA (`fetch_payload`).

| Payload | Ставит | Куда | Примечание |
|---|---|---|---|
| `podkop-health.sh` | lib/podkop.sh (`podkop_health_install`) | `/usr/libexec/warren/podkop-health.sh` | единая проверка Podkop: source в lib/podkop.sh и watchdog, `sh … snapshot` из LuCI |
| `warren-tg-bot`, `.init` | lib/tg_bot.sh | `/usr/bin/warren-tg-bot`, `/etc/init.d/warren-tg-bot` | 1390 строк; `amz_*` дублирует lib/amneziawg.sh |
| `warren-watchdog`, `.init` | lib/watchdog.sh | `/usr/libexec/warren/warren-watchdog`, `/etc/init.d/warren-watchdog` | health — через podkop-health.sh |
| `warren-remote-agent`, `warren-remote-admin.init` | lib/remote_admin.sh, Mac tool | `/usr/bin/warren-remote-agent`, `/etc/init.d/warren-remote-admin` | source-ит свой конфиг |
| `warren-remote` | lib/remote_admin.sh, Mac tool | VPS `/usr/local/bin/warren-remote` | protocol helper |
| `check-sni.sh` (bash), `sni-apply.py` | lib/sni_checker.sh | VPS | SNI check / apply |
| `warren-qos.init` | lib/qos.sh | `/etc/init.d/warren-qos` | вызывает `warren --apply-qos` |

LuCI runner ставится из `luci-app-warren/root/usr/libexec/warren/warren-luci-run`.

## Целостность и доставка

Манифест — три строки в `warren.sh`: `WARREN_LIB_LIST` (заодно порядок `source_lib`), `WARREN_ASSET_LIST`,
`WARREN_PAYLOAD_LIST`. `tools/manifest.sh` печатает по ним полный список файлов для `update-sums.sh` и
`build-router-upload.sh`, а `check.sh` падает, если файл из `lib/` или `payload/` не внесён в список.

`VERSION` (версия + `SUMS_SHA256`) → `SUMS.txt` → каждый download проверяется до `mv`
(`warren_download_retry`, `warren_fetch_file`, self-update, bootstrap). После изменения runtime-файла:
`sh tools/update-sums.sh`.

## Версии внешних компонентов

Всё в `lib/versions.sh` (`warren_versions_apply_defaults`): Podkop installer `0.7.21` + SHA, 3x-ui `v3.5.0` + SHA,
AmneziaWG — exact `v${DISTRIB_RELEASE}` из `Slava-Shchipunov/awg-openwrt`, иначе same-family fallback
(`warren_awg_select_release`). OpenWrt `26+` — graceful mode (`WARREN_ALLOW_UNKNOWN_OPENWRT=1`).

## Проверки

| Команда | Где | Что |
|---|---|---|
| `sh tools/check.sh` | Mac/Linux, без сети | синтаксис (sh/bash/python), манифест, SUMS, SYMBOLS, `tests/run.sh` (51 тест), upload bundle |
| `sh tools/build-router-upload.sh [dir]` | Mac | одноразовый bundle для scp на роутер |
| `sh tools/test-e2e.sh` | Mac + живой R5S + VPS (`.env`) | прошивка, auto, VPS, Remote Admin, watchdog; артефакты в `tools/test-runs/` |
| `sh tools/wg-vless-chain-diagnostics.sh` | Mac | цепочка WG → OpenWrt → Podkop → VLESS (не встроен в меню) |

## Горячие точки для рефакторинга

Сделано: payloads вынесены в `payload/` (Mac-инструмент больше не держит свою копию агента),
единый манифест файлов, expand-root вендорён в `assets/`, реестр режимов `lib/modes.sh`,
единая проверка Podkop `payload/podkop-health.sh`.

1. **Общий runtime для payload-ов** (`log`, `now_epoch`, `safe_text`) и переиспользование AWG/QoS в tg-bot.
2. **Разрезать крупные файлы**: `lib/vps.sh` (1374: SSH-транспорт / 3x-ui API / Reality / reports),
   `warren.sh` (bootstrap+self-update отдельно от orchestrator), `lib/sni_checker.sh` (check vs apply).
3. **Remote Admin agent** source-ит `/etc/warren/warren-remote-admin.conf` — перевести на whitelist-парсер как M16.
4. **LuCI**: Lua-контроллер (`luci-compat`) и 755-строчный view; при 25.x стоит оценить переход на JS/rpcd.
