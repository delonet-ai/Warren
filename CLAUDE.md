# Warren

POSIX `sh` установщик/помощник для OpenWrt (NanoPi R5S/R5C): basic + expand-root → VPS (3x-ui, VLESS Reality)
→ Podkop → AmneziaWG → QoS, Watchdog, TG-бот, Remote Admin, LuCI UI.

- Карта кода: [docs/INDEX.md](docs/INDEX.md). Все функции по файлам: [docs/SYMBOLS.md](docs/SYMBOLS.md).
- Roadmap и статусы milestones — только в [TECHNICAL_README.md](TECHNICAL_README.md#milestones-разработки).

## Правила

- Роутерный код — только POSIX `sh` + BusyBox (ash): без bash-измов, `local`, массивов, `[[ ]]`, GNU-флагов (VPS-payload SNI checker — bash).
- Не использовать `eval` и не source-ить конфиг; новые ключи `warren.conf` добавлять в
  `warren_assign_config_key` (`lib/state.sh`), поля LuCI-формы — в `write_form_env` (`controller/warren.lua`).
- Новый модуль `lib/*.sh`: добавить в `WARREN_LIB_LIST` (`warren.sh`) и `PAYLOADS` (`tools/update-sums.sh`).
- Новый режим: `menu` (`lib/ui.sh`), `run_service_mode`/`mode_is_one_shot_service` (`warren.sh`), кнопка в LuCI view.
- Функции внутри heredoc payload-ов исполняются на роутере/VPS отдельным процессом и не видят `lib/*.sh`.
- Сообщения пользователю — на русском; секреты не логировать (`log` маскирует PASSWORD/TOKEN/SECRET).

## После изменений

```sh
sh tools/update-sums.sh   # если менялся любой runtime-файл (warren.sh, lib, assets, luci-app-warren)
sh tools/gen-index.sh     # если добавлены/переименованы функции или файлы
sh tools/check.sh         # всё локально: syntax, SUMS, SYMBOLS, tests/run.sh, upload bundle
```

Живой прогон: `sh tools/test-e2e.sh` (нужен R5S на 192.168.1.1 и VPS из `.env`). Не коммитить `.env`,
`tools/os/`, `tools/test-runs/`, `diagnostics/`, `.warren-dev/`.
