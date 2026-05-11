amnezia_require_podkop() {
  uciq get podkop.main >/dev/null || fail "Сначала настрой Podkop, потом доустанавливай Amnezia."
}

amnezia_backend_notice() {
  say ""
  say "${YELLOW}INFO${NC}  Amnezia Private использует AmneziaWG."
  say "Сначала ставим exact-пакеты под эту OpenWrt, потом поднимаем awg0 и создаём клиентов."
}

amnezia_print_awg_summary() {
  say ""
  say "=== Amnezia Private ==="
  say "Backend: AmneziaWG"
  say "Server interface: ${AWG_IFACE}"
  say "Server address: ${AWG_SERVER_IP}/24"
  say "Endpoint: ${AWG_ENDPOINT:-не задан}"
  say "Client configs dir: ${AWG_CLIENT_DIR}"
  say ""
  say "Клиенты:"
  if [ -d "$AWG_CLIENT_DIR" ] && ls -1 "$AWG_CLIENT_DIR"/*.conf >/dev/null 2>&1; then
    for conf_file in "$AWG_CLIENT_DIR"/*.conf; do
      [ -f "$conf_file" ] || continue
      say " - $conf_file"
    done
  else
    say " - пока нет"
  fi
  say ""
  say "Podkop source interfaces:"
  uci -q get podkop.settings.source_network_interfaces 2>/dev/null | sed 's/^/ - /'
  say ""
}

amnezia_collect_clients_count() {
  ask "Сколько private-клиентов создать сейчас? (0 = только сервер)" PEERS "${PEERS:-1}"
  case "$PEERS" in
    ''|*[!0-9]*)
      fail "Количество клиентов должно быть числом"
      ;;
  esac
}

amnezia_create_initial_awg_clients() {
  i=1
  while [ "$i" -le "$PEERS" ]; do
    default_name="peer$i"
    ask "Имя клиента #$i" name "$default_name"
    [ -n "$name" ] || fail "Имя клиента пустое"
    ip="$(awg_next_free_ip32)" || fail "Не нашёл свободный IP для AWG-клиента"
    create_amneziawg_peer "$name" "$ip"
    i=$((i+1))
  done
}

run_amnezia_private_flow() {
  amnezia_require_podkop
  amnezia_backend_notice

  st="$(get_state)"

  command -v awg >/dev/null 2>&1 || st=0
  [ -f "$AWG_SERVER_DIR/server.key" ] || [ "$st" -lt 100 ] || st=100
  uci -q get network."$AWG_IFACE".proto 2>/dev/null | grep -qx 'amneziawg' || [ "$st" -lt 110 ] || st=110

  if [ "$st" -lt 100 ]; then
    install_amneziawg
    set_state 100
  fi

  if [ "$st" -lt 110 ]; then
    configure_amneziawg_server
    set_state 110
  fi

  if [ "$MODE" = "add_private" ] && [ "$st" -lt 115 ]; then
    patch_podkop_add_private_iface_only "$AWG_IFACE"
    set_state 115
  fi

  if [ "$st" -lt 120 ]; then
    amnezia_collect_clients_count
    if [ "$PEERS" -gt 0 ]; then
      amnezia_create_initial_awg_clients
    fi
    set_state 120
  fi

  amnezia_print_awg_summary
}

run_amnezia_manage_flow() {
  amnezia_backend_notice
  amneziawg_manage_menu
}
