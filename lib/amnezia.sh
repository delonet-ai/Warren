amnezia_require_podkop() {
  uciq get podkop.main >/dev/null || fail "Сначала настрой Podkop, потом доустанавливай Amnezia."
}

resolve_amnezia_backend() {
  AMNEZIA_BACKEND="${AMNEZIA_BACKEND:-awg}"
  case "$AMNEZIA_BACKEND" in
    awg|wg) ;;
    *)
      fail "Неизвестный backend private access: $AMNEZIA_BACKEND"
      ;;
  esac
}

select_amnezia_backend() {
  resolve_amnezia_backend
  say ""
  say "Private backend:"
  say "1) AmneziaWG (новый backend)"
  say "2) WireGuard fallback"
  ask "Выбор backend (1-2)" AMNEZIA_BACKEND_CHOICE "$( [ "$AMNEZIA_BACKEND" = "awg" ] && echo 1 || echo 2 )"

  case "$AMNEZIA_BACKEND_CHOICE" in
    1) AMNEZIA_BACKEND="awg" ;;
    2) AMNEZIA_BACKEND="wg" ;;
    *) fail "Введи 1 или 2" ;;
  esac

  conf_set AMNEZIA_BACKEND "$AMNEZIA_BACKEND"
  runtime_state_set "amnezia_backend" "$AMNEZIA_BACKEND"
}

amnezia_backend_notice() {
  resolve_amnezia_backend
  say ""
  case "$AMNEZIA_BACKEND" in
    awg)
      say "${YELLOW}INFO${NC}  Выбран backend AmneziaWG."
      say "Сейчас идём безопасным миграционным путём: новый backend разворачивается рядом со старым WG fallback."
      ;;
    wg)
      say "${YELLOW}INFO${NC}  Выбран WireGuard fallback backend."
      say "Это старый рабочий путь, пока AmneziaWG ещё доводится."
      ;;
  esac
}

amnezia_print_wg_summary() {
  say ""
  say "=== Amnezia Private ==="
  say "Backend: WireGuard fallback"
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

amnezia_print_awg_summary() {
  say ""
  say "=== Amnezia Private ==="
  say "Backend: AmneziaWG"
  say "Server interface: ${AWG_IFACE}"
  say "Server address: ${AWG_SERVER_IP}/24"
  say "Endpoint: ${WG_ENDPOINT:-не задан}"
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

amnezia_create_initial_wg_clients() {
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

run_amnezia_private_flow_wg() {
  st="$(get_state)"

  command -v wg >/dev/null 2>&1 || st=0
  [ -f /etc/wireguard/server.key ] || [ "$st" -lt 100 ] || st=100
  uci -q get network.wg0.proto 2>/dev/null | grep -qx 'wireguard' || [ "$st" -lt 110 ] || st=110

  [ "$st" -lt 100 ] && install_wireguard && set_state 100
  [ "$st" -lt 110 ] && configure_wireguard_server && set_state 110
  [ "$MODE" = "add_private" ] && [ "$st" -lt 115 ] && patch_podkop_add_wg0_only && set_state 115

  if [ "$st" -lt 120 ]; then
    amnezia_collect_clients_count
    [ "$PEERS" -gt 0 ] && amnezia_create_initial_wg_clients
    set_state 120
  fi

  amnezia_print_wg_summary
}

run_amnezia_private_flow_awg() {
  st="$(get_state)"

  command -v awg >/dev/null 2>&1 || st=0
  [ -f "$AWG_SERVER_DIR/server.key" ] || [ "$st" -lt 100 ] || st=100
  uci -q get network."$AWG_IFACE".proto 2>/dev/null | grep -qx 'amneziawg' || [ "$st" -lt 110 ] || st=110

  [ "$st" -lt 100 ] && install_amneziawg && set_state 100
  [ "$st" -lt 110 ] && configure_amneziawg_server && set_state 110
  [ "$MODE" = "add_private" ] && [ "$st" -lt 115 ] && patch_podkop_add_private_iface_only "$AWG_IFACE" && set_state 115

  if [ "$st" -lt 120 ]; then
    amnezia_collect_clients_count
    [ "$PEERS" -gt 0 ] && amnezia_create_initial_awg_clients
    set_state 120
  fi

  amnezia_print_awg_summary
}

run_amnezia_private_flow() {
  amnezia_require_podkop
  select_amnezia_backend
  amnezia_backend_notice

  case "$AMNEZIA_BACKEND" in
    awg) run_amnezia_private_flow_awg ;;
    wg) run_amnezia_private_flow_wg ;;
  esac
}

run_amnezia_manage_flow() {
  resolve_amnezia_backend
  amnezia_backend_notice
  case "$AMNEZIA_BACKEND" in
    awg) amneziawg_manage_menu ;;
    wg) wg_manage_menu ;;
  esac
}
