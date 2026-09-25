# Warren

POSIX `sh` установщик/помощник для OpenWrt (NanoPi R5S/R5C): basic + expand-root → VPS (3x-ui, VLESS Reality)
→ Podkop → AmneziaWG → QoS, Watchdog, TG-бот, Remote Admin, LuCI UI.

- Карта кода: [docs/INDEX.md](docs/INDEX.md). Все функции по файлам: [docs/SYMBOLS.md](docs/SYMBOLS.md).
- Roadmap и статусы milestones — только в [TECHNICAL_README.md](TECHNICAL_README.md#milestones-разработки).

## Правила

- Роутерный код — только POSIX `sh` + BusyBox (ash): без bash-измов, `local`, массивов, `[[ ]]`, GNU-флагов (`payload/check-sni.sh` для VPS — bash).
- Не использовать `eval` и не source-ить конфиг; новые ключи `warren.conf` добавлять в
  `warren_assign_config_key` (`lib/state.sh`), поля LuCI-формы — в `write_form_env` (`controller/warren.lua`).
- Новый файл в `lib/`, `assets/` или `payload/`: добавить в `WARREN_LIB_LIST` / `WARREN_ASSET_LIST` /
  `WARREN_PAYLOAD_LIST` (`warren.sh`) — это единственный манифест; `check.sh` ловит пропуски.
- Новый режим — одна строка в `WARREN_MODES` (`lib/modes.sh`): меню, диспетчер и resume строятся из неё;
  кнопка LuCI (`name="mode" value="..."`) должна ссылаться на режим из реестра — это проверяет `tests/run.sh`.
- Сервисы для роутера/VPS — отдельные файлы в `payload/`, ставятся через `warren_install_payload`;
  они работают отдельным процессом и не видят `lib/*.sh`. Не встраивать скрипты heredoc-ом.
- Сообщения пользователю — на русском; секреты не логировать (`log` маскирует PASSWORD/TOKEN/SECRET).

## После изменений

```sh
sh tools/update-sums.sh   # если менялся любой runtime-файл (warren.sh, lib, assets, luci-app-warren)
sh tools/gen-index.sh     # если добавлены/переименованы функции или файлы
sh tools/check.sh         # всё локально: syntax, SUMS, SYMBOLS, tests/run.sh, upload bundle
```

Живой прогон: `sh tools/test-e2e.sh` (нужен R5S на 192.168.1.1 и VPS из `.env`). Не коммитить `.env`,
`tools/os/`, `tools/test-runs/`, `diagnostics/`, `.warren-dev/`.
