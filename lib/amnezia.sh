amnezia_backend_notice() {
  say ""
  say "${YELLOW}INFO${NC}  Пока для private access используется текущий WireGuard backend."
  say "Название и UX уже готовятся под AmneziaWG, а переход логики будет следующим этапом."
}

run_amnezia_private_flow() {
  st="$(get_state)"
  amnezia_backend_notice

  [ "$st" -lt 100 ] && install_wireguard && set_state 100
  [ "$st" -lt 110 ] && configure_wireguard_server && set_state 110
  [ "$MODE" = "add_private" ] && [ "$st" -lt 115 ] && patch_podkop_add_wg0_only && set_state 115

  if [ "$st" -lt 120 ]; then
    ask "Сколько клиентов Private создать сейчас?" PEERS "1"
    i=1
    while [ "$i" -le "$PEERS" ]; do
      name="peer$i"
      ip="10.10.10.$((i+1))/32"
      create_peer "$name" "$ip"
      i=$((i+1))
    done
    set_state 120
  fi
}

run_amnezia_manage_flow() {
  amnezia_backend_notice
  wg_manage_menu
}
