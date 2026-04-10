install_podkop() {
  download_file "$PODKOP_INSTALL_URL" /tmp/podkop-install.sh "$PODKOP_INSTALL_SHA256" "PODKOP_INSTALL"
  chmod +x /tmp/podkop-install.sh

  if [ -r /dev/tty ]; then
    sh /tmp/podkop-install.sh </dev/tty >/dev/tty 2>&1
  else
    fail "Нет /dev/tty. Запусти через интерактивный SSH или: ssh -t root@ip 'sh /tmp/warren.sh'"
  fi

  done_ "Podkop установлен/обновлён"
}

configure_podkop_full() {
  if [ -z "${VLESS:-}" ]; then
    warn "VLESS пустой — сейчас спрошу заново."
    ask "Вставь строку VLESS (одной строкой)" VLESS ""
    conf_set VLESS "$VLESS"
  fi
  [ -n "${VLESS:-}" ] || fail "VLESS пустой. Запусти скрипт заново и введи VLESS (MODE 1/2)."

  uciq get podkop.settings >/dev/null || uciq set podkop.settings='settings'
  uciq set podkop.settings.dns_type='doh'
  uciq set podkop.settings.dns_server='1.1.1.1'
  uciq set podkop.settings.bootstrap_dns_server='77.88.8.8'
  uciq set podkop.settings.dns_rewrite_ttl='60'
  uciq set podkop.settings.enable_output_network_interface='0'
  uciq set podkop.settings.enable_badwan_interface_monitoring='0'
  uciq set podkop.settings.enable_yacd='0'
  uciq set podkop.settings.disable_quic='0'
  uciq set podkop.settings.update_interval='1d'
  uciq set podkop.settings.download_lists_via_proxy='0'
  uciq set podkop.settings.dont_touch_dhcp='0'
  uciq set podkop.settings.config_path='/etc/sing-box/config.json'
  uciq set podkop.settings.cache_path='/tmp/sing-box/cache.db'
  uciq set podkop.settings.exclude_ntp='0'
  uciq set podkop.settings.shutdown_correctly='0'

  uciq -q del podkop.settings.source_network_interfaces
  uciq add_list podkop.settings.source_network_interfaces='br-lan'
  if [ "$MODE" = "2" ] || [ "$MODE" = "3" ]; then
    uciq add_list podkop.settings.source_network_interfaces='wg0'
  fi

  uciq get podkop.main >/dev/null || uciq set podkop.main='section'
  uciq set podkop.main.connection_type='proxy'
  uciq set podkop.main.proxy_config_type='url'
  uciq set podkop.main.enable_udp_over_tcp='0'
  uciq set podkop.main.proxy_string="$VLESS"
  uciq set podkop.main.user_domain_list_type='dynamic'
  uciq set podkop.main.user_subnet_list_type='disabled'
  uciq set podkop.main.mixed_proxy_enabled='0'

  uciq -q del podkop.main.community_lists
  [ "${LIST_RU:-0}" = "1" ] && uciq add_list podkop.main.community_lists='russia_inside'
  [ "${LIST_CF:-0}" = "1" ] && uciq add_list podkop.main.community_lists='cloudflare'
  [ "${LIST_META:-0}" = "1" ] && uciq add_list podkop.main.community_lists='meta'
  [ "${LIST_GOOGLE_AI:-0}" = "1" ] && uciq add_list podkop.main.community_lists='google_ai'

  uciq commit podkop
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
  done_ "Podkop настроен и перезапущен"
}

patch_podkop_add_wg0_only() {
  uciq get podkop.settings >/dev/null || uciq set podkop.settings='settings'
  if ! uci -q get podkop.settings.source_network_interfaces 2>/dev/null | grep -q 'wg0'; then
    uciq add_list podkop.settings.source_network_interfaces='wg0'
    uciq commit podkop
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
  fi
  done_ "Podkop: wg0 добавлен в source_network_interfaces"
}
