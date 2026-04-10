amnezia_backend_notice() {
  say ""
  say "${YELLOW}INFO${NC}  Пока для private access используется текущий WireGuard backend."
  say "Название и UX уже готовятся под AmneziaWG, а переход логики будет следующим этапом."
}

amnezia_require_podkop() {
  uciq get podkop.main >/dev/null || fail "Сначала настрой Podkop, потом доустанавливай Amnezia."
}

amnezia_print_summary() {
  say ""
  say "=== Amnezia Private ==="
  say "Backend: WireGuard (временный до перехода на AmneziaWG)"
  say "Server interface: wg0"
  say "Server address: ${WG_SERVER_IP}/24"
  say "Endpoint: ${WG_ENDPOINT:-не задан}"
  say "Client configs dir: $WG_CLIENT_DIR"
  say ""
  say "Клиенты:"
  if [ -d "$WG_CLIENT_DIR" ] && ls -1 "$WG_CLIENT_DIR"/*.conf >/dev/null 2>&1; then
    for conf_file in "$WG_CLIENT_DIR"/*.conf; do
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
  ask "Сколько клиентов Private создать сейчас? (0 = только сервер)" PEERS "${PEERS:-1}"
  case "$PEERS" in
    ''|*[!0-9]*)
      fail "Количество клиентов должно быть числом"
      ;;
  esac
}

amnezia_create_initial_clients() {
  i=1
  while [ "$i" -le "$PEERS" ]; do
    default_name="peer$i"
    ask "Имя клиента #$i" name "$default_name"
    [ -n "$name" ] || fail "Имя клиента пустое"
    ip="10.10.10.$((i+1))/32"
    create_peer "$name" "$ip"
    i=$((i+1))
  done
}

run_amnezia_private_flow() {
  st="$(get_state)"
  amnezia_backend_notice
  amnezia_require_podkop

  [ "$st" -lt 100 ] && install_wireguard && set_state 100
  [ "$st" -lt 110 ] && configure_wireguard_server && set_state 110
  [ "$MODE" = "add_private" ] && [ "$st" -lt 115 ] && patch_podkop_add_wg0_only && set_state 115

  if [ "$st" -lt 120 ]; then
    amnezia_collect_clients_count
    [ "$PEERS" -gt 0 ] && amnezia_create_initial_clients
    set_state 120
  fi

  amnezia_print_summary
}

run_amnezia_manage_flow() {
  amnezia_backend_notice
  wg_manage_menu
}
