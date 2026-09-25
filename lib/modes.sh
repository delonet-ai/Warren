# Mode registry: the only list of Warren modes.
#
# mode|menu|kind|target|handler|label
#   menu    main menu item ("4"), submenu item ("4.1") or "-" (LuCI/internal only)
#   kind    flow     resumable state machine up to <target> (run_basic_flow & co.)
#           service  one-shot: run <handler>, clear MODE, exit
#           submenu  menu entry that opens the "<menu>.N" items
#   handler function for service/submenu kinds, "-" otherwise
WARREN_MODES='
auto|0|flow|100|-|Полный авторежим
basic|1|flow|75|-|Базовые настройки
initialize|2|service|0|install_warren_luci_ui|Добавить UI Warren в роутер
vps|3|service|0|run_vps_flow|Настрой мне VPS
podkop|4|submenu|0|-|Podkop
podkop_setup|4.1|flow|95|-|Стандартная настройка
podkop_backup|4.2|service|0|add_podkop_backup_channel|Добавить резервный канал
add_private|5|flow|120|-|Доустановить Amnezia в Podkop
qos_private|6|service|0|run_qos_flow|QoS для Amnezia
manage_private|7|service|0|run_amnezia_manage_flow|Управление Amnezia клиентами
remote_admin|8|service|0|run_remote_admin_flow|Remote Admin
usb_modem|9|service|0|run_usb_modem_flow|USB модем настрой (WIP, Milestone 11)
tg_bot|10|service|0|run_tg_bot_flow|Telegram-бот для Podkop
diagnostics|11|service|0|run_diagnostics_flow|Диагностика Podkop/VPS
sni_checker|12|service|0|run_sni_checker_flow|Проверка SNI-кандидатов Reality
sni_apply|13|service|0|run_sni_apply_flow|Применить SNI к VPS/Podkop
naiveproxy_wip|14|service|0|run_naiveproxy_wip_flow|NaiveProxy (WIP, Milestone 12)
shadowsocks_fallback_wip|15|service|0|run_shadowsocks_fallback_wip_flow|Shadowsocks fallback (WIP, Milestone 9)
remote_admin_console|16|service|0|run_remote_admin_console|Remote Admin Console (Mac)
rf_bundle_wip|99|service|0|run_rf_bundle_wip_flow|Установить всё из РФ сегмента (WIP, Milestone 10)
diagnostics_emergency|-|service|0|run_diagnostics_emergency_flow|Диагностика с DNS-fallback
amnezia_client_create|-|service|0|run_amnezia_client_create_flow|Создать Amnezia-клиента
amnezia_client_delete|-|service|0|run_amnezia_client_delete_flow|Удалить Amnezia-клиента
remote_admin_config|-|service|0|run_remote_admin_config_flow|Сохранить конфиг Remote Admin
remote_admin_poll_now|-|service|0|remote_admin_poll_now_flow|Remote Admin: проверить сейчас
remote_admin_router_install|-|service|0|remote_admin_install_router_agent|Remote Admin: установить router agent
remote_admin_vps_install|-|service|0|remote_admin_install_vps_helper|Remote Admin: установить VPS helper
watchdog_enable|-|service|0|watchdog_enable|Включить Podkop Watchdog
watchdog_disable|-|service|0|watchdog_disable|Выключить Podkop Watchdog
watchdog_reset|-|service|0|watchdog_reset|Сбросить счётчик Podkop Watchdog
'

# warren_mode_field <mode> <column 1-6>
warren_mode_field() {
  printf "%s\n" "$WARREN_MODES" | awk -F'|' -v m="$1" -v c="$2" '$1 == m { print $c; found = 1; exit } END { if (!found) exit 1 }'
}

warren_mode_known() {
  warren_mode_field "$1" 1 >/dev/null
}

warren_mode_kind() {
  warren_mode_field "${1:-}" 3 2>/dev/null || true
}

# warren_mode_by_menu <item> -> mode, e.g. "4.2" -> podkop_backup
warren_mode_by_menu() {
  printf "%s\n" "$WARREN_MODES" | awk -F'|' -v n="$1" '$2 == n { print $1; found = 1; exit } END { if (!found) exit 1 }'
}

# warren_menu_items <prefix>: "N) label" lines for "N" (prefix "") or "<prefix>.N" items.
warren_menu_items() {
  printf "%s\n" "$WARREN_MODES" | awk -F'|' -v p="$1" '
    NF < 6 || $2 == "-" { next }
    p == "" && $2 !~ /\./ { print $2 ") " $6 }
    p != "" && index($2, p ".") == 1 { print substr($2, length(p) + 2) ") " $6 }
  '
}

# Prompt hint for the main menu, e.g. "0-16, 99".
warren_menu_range() {
  printf "%s\n" "$WARREN_MODES" | awk -F'|' '
    NF < 6 || $2 == "-" || $2 ~ /\./ { next }
    { n[$2 + 0] = 1; if ($2 + 0 > max) max = $2 + 0 }
    END {
      top = 0
      while (n[top + 1]) top++
      out = "0-" top
      for (i = top + 1; i <= max; i++) if (n[i]) out = out ", " i
      print out
    }
  '
}

mode_target_state() {
  target="$(warren_mode_field "${MODE:-}" 4 2>/dev/null)" || target=0
  printf "%s\n" "${target:-0}"
}

mode_is_one_shot_service() {
  [ "$(warren_mode_kind "${MODE:-}")" != "flow" ]
}

mode_is_podkop() {
  [ "$MODE" = "podkop_setup" ] || [ "$MODE" = "auto" ]
}

mode_is_private() {
  [ "$MODE" = "add_private" ]
}

# Run a one-shot service mode and exit; return 1 for flow modes.
run_service_mode() {
  [ "$(warren_mode_kind "${MODE:-}")" = "service" ] || return 1
  _wm_handler="$(warren_mode_field "$MODE" 5)"
  "$_wm_handler"

  conf_set MODE ""
  cleanup_runtime_state
  exit 0
}
