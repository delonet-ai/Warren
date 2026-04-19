podkop_private_iface() {
  printf "awg0"
}

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

podkop_require_existing_config() {
  uciq get podkop.main >/dev/null || fail "Podkop ещё не настроен. Сначала выполни стандартную настройку."
}

podkop_standard_choose_vless() {
  while :; do
    report_list="$(vps_report_files)"
    report_count="$(printf "%s\n" "$report_list" | sed '/^$/d' | wc -l | tr -d ' ')"

    say ""
    say "Источник VLESS для Podkop:"

    if [ "${report_count:-0}" -gt 0 ]; then
      option_index=1
      printf "%s\n" "$report_list" | while IFS= read -r report_file; do
        [ -n "$report_file" ] || continue
        say "$option_index) Конфиг VPS: $(basename "$report_file" .txt)"
        option_index=$((option_index + 1))
      done
      manual_option=$((report_count + 1))
      say "$manual_option) Ввести ссылку вручную"
      say "0) Назад"
      ask "Ввод (0-$manual_option)" PODKOP_VLESS_CHOICE "1"

      case "$PODKOP_VLESS_CHOICE" in
        0)
          return 1
          ;;
        ''|*[!0-9]*)
          fail "Введи номер варианта"
          ;;
      esac

      if [ "$PODKOP_VLESS_CHOICE" -ge 1 ] && [ "$PODKOP_VLESS_CHOICE" -le "$report_count" ]; then
        SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n "${PODKOP_VLESS_CHOICE}p")"
        [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось определить выбранный VPS-конфиг"
        VLESS="$(vps_report_vless_link "$SELECTED_VPS_REPORT")"
        [ -n "$VLESS" ] || fail "Не удалось прочитать VLESS из отчёта VPS: $SELECTED_VPS_REPORT"
        conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
        conf_set VLESS "$VLESS"
        return 0
      fi

      [ "$PODKOP_VLESS_CHOICE" -eq "$manual_option" ] || fail "Нет варианта с номером $PODKOP_VLESS_CHOICE"
    else
      say "1) Ввести ссылку вручную"
      say "0) Назад"
      ask "Ввод (0-1)" PODKOP_VLESS_CHOICE "1"
      case "$PODKOP_VLESS_CHOICE" in
        0)
          return 1
          ;;
        1) ;;
        *)
          fail "Введи 0 или 1"
          ;;
      esac
    fi

    ask "Вставь строку VLESS (одной строкой, 0 = назад)" VLESS "${VLESS:-}"
    [ "$VLESS" = "0" ] && continue
    [ -n "${VLESS:-}" ] || fail "VLESS пустой."
    SELECTED_VPS_REPORT=""
    conf_set SELECTED_VPS_REPORT ""
    conf_set VLESS "$VLESS"
    return 0
  done
}

podkop_prompt_lists() {
  say ""
  say "Списки (community_lists) — 0/1:"
  ask "russia_inside" LIST_RU "${LIST_RU:-1}"
  ask "cloudflare" LIST_CF "${LIST_CF:-1}"
  ask "meta" LIST_META "${LIST_META:-1}"
  ask "google_ai" LIST_GOOGLE_AI "${LIST_GOOGLE_AI:-1}"

  conf_set LIST_RU "$LIST_RU"
  conf_set LIST_CF "$LIST_CF"
  conf_set LIST_META "$LIST_META"
  conf_set LIST_GOOGLE_AI "$LIST_GOOGLE_AI"
}

configure_podkop_common_settings() {
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
  if [ "$MODE" = "add_private" ]; then
    uciq add_list podkop.settings.source_network_interfaces="$(podkop_private_iface)"
  fi

  uciq get podkop.main >/dev/null || uciq set podkop.main='section'
  uciq set podkop.main.connection_type='proxy'
  uciq set podkop.main.enable_udp_over_tcp='0'
  uciq set podkop.main.user_domain_list_type='dynamic'
  uciq set podkop.main.user_subnet_list_type='disabled'
  uciq set podkop.main.mixed_proxy_enabled='0'
}

configure_podkop_community_lists() {
  uciq -q del podkop.main.community_lists
  [ "${LIST_RU:-0}" = "1" ] && uciq add_list podkop.main.community_lists='russia_inside'
  [ "${LIST_CF:-0}" = "1" ] && uciq add_list podkop.main.community_lists='cloudflare'
  [ "${LIST_META:-0}" = "1" ] && uciq add_list podkop.main.community_lists='meta'
  [ "${LIST_GOOGLE_AI:-0}" = "1" ] && uciq add_list podkop.main.community_lists='google_ai'
}

configure_podkop_full() {
  podkop_standard_choose_vless || return 1
  podkop_prompt_lists

  [ -n "${VLESS:-}" ] || fail "VLESS пустой."

  configure_podkop_common_settings
  uciq set podkop.main.proxy_config_type='url'
  uciq set podkop.main.proxy_string="$VLESS"
  uciq -q del podkop.main.urltest_proxy_links
  uciq -q del podkop.main.selector_proxy_links
  configure_podkop_community_lists

  uciq commit podkop
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
  done_ "Podkop настроен и перезапущен"
  return 0
}

podkop_current_proxy_links() {
  current_type="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || true)"

  case "$current_type" in
    urltest)
      uci show podkop.main 2>/dev/null | sed -n "s/^podkop\.main\.urltest_proxy_links='\(.*\)'$/\1/p"
      ;;
    url)
      uci -q get podkop.main.proxy_string 2>/dev/null
      ;;
    *)
      uci -q get podkop.main.proxy_string 2>/dev/null
      ;;
  esac
}

podkop_link_in_list() {
  needle="$1"
  list_data="$2"
  printf "%s\n" "$list_data" | grep -Fxq -- "$needle"
}

podkop_backup_candidate_menu() {
  added_links="$1"
  report_list="$(vps_report_files)"

  say ""
  say "Уже добавлены в Podkop:"
  added_index=1
  printf "%s\n" "$added_links" | sed '/^$/d' | while IFS= read -r added_link; do
    say "$added_index) $added_link"
    added_index=$((added_index + 1))
  done

  say ""
  say "Доступные конфиги VPS:"
  candidate_count=0
  : > /tmp/warren-podkop-candidates.$$ || true
  if [ -n "$report_list" ]; then
    printf "%s\n" "$report_list" | while IFS= read -r report_file; do
      [ -n "$report_file" ] || continue
      report_vless="$(vps_report_vless_link "$report_file")"
      [ -n "$report_vless" ] || continue
      if podkop_link_in_list "$report_vless" "$added_links"; then
        continue
      fi
      candidate_count=$((candidate_count + 1))
      printf "%s\t%s\n" "$report_file" "$report_vless" >> /tmp/warren-podkop-candidates.$$
      say "$candidate_count) $(basename "$report_file" .txt)"
    done
  fi

  candidate_count="$(wc -l < /tmp/warren-podkop-candidates.$$ 2>/dev/null | tr -d ' ')"
  manual_option=$((candidate_count + 1))
  say "$manual_option) Ввести ссылку вручную"
  say "0) Назад"
  ask "Выбор канала" PODKOP_BACKUP_CHOICE "$manual_option"

  case "$PODKOP_BACKUP_CHOICE" in
    0)
      rm -f /tmp/warren-podkop-candidates.$$ 2>/dev/null || true
      return 1
      ;;
    ''|*[!0-9]*)
      rm -f /tmp/warren-podkop-candidates.$$ 2>/dev/null || true
      fail "Введи номер варианта"
      ;;
  esac

  if [ "$PODKOP_BACKUP_CHOICE" -ge 1 ] && [ "$PODKOP_BACKUP_CHOICE" -le "$candidate_count" ]; then
    selected_line="$(sed -n "${PODKOP_BACKUP_CHOICE}p" /tmp/warren-podkop-candidates.$$)"
    rm -f /tmp/warren-podkop-candidates.$$ 2>/dev/null || true
    BACKUP_SOURCE_REPORT="$(printf "%s" "$selected_line" | cut -f1)"
    BACKUP_SOURCE_VLESS="$(printf "%s" "$selected_line" | cut -f2-)"
    [ -n "$BACKUP_SOURCE_VLESS" ] || fail "Не удалось прочитать VLESS из выбранного VPS-конфига"
    return 0
  fi

  [ "$PODKOP_BACKUP_CHOICE" -eq "$manual_option" ] || {
    rm -f /tmp/warren-podkop-candidates.$$ 2>/dev/null || true
    fail "Нет варианта с номером $PODKOP_BACKUP_CHOICE"
  }

  rm -f /tmp/warren-podkop-candidates.$$ 2>/dev/null || true
  ask "Вставь резервную строку VLESS (0 = назад)" BACKUP_SOURCE_VLESS ""
  [ "$BACKUP_SOURCE_VLESS" = "0" ] && return 1
  [ -n "$BACKUP_SOURCE_VLESS" ] || fail "Резервный VLESS пустой."
  BACKUP_SOURCE_REPORT=""
  return 0
}

podkop_apply_urltest_links() {
  links="$1"

  configure_podkop_common_settings
  uciq set podkop.main.proxy_config_type='urltest'
  uciq -q del podkop.main.proxy_string
  uciq -q del podkop.main.urltest_proxy_links
  printf "%s\n" "$links" | sed '/^$/d' | while IFS= read -r link; do
    uciq add_list podkop.main.urltest_proxy_links="$link"
  done
  uciq set podkop.main.urltest_check_interval='3m'
  uciq set podkop.main.urltest_tolerance='50'
  uciq set podkop.main.urltest_testing_url='https://www.gstatic.com/generate_204'
  uciq commit podkop
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

podkop_print_active_urltest_links() {
  active_links="$(uci show podkop.main 2>/dev/null | sed -n "s/^podkop\.main\.urltest_proxy_links='\(.*\)'$/\1/p")"
  say ""
  say "Активные URLTest каналы Podkop:"
  if [ -n "$active_links" ]; then
    link_index=1
    printf "%s\n" "$active_links" | sed '/^$/d' | while IFS= read -r active_link; do
      say "$link_index) $active_link"
      link_index=$((link_index + 1))
    done
  else
    say "Список пуст"
  fi
}

add_podkop_backup_channel() {
  podkop_require_existing_config

  current_links="$(podkop_current_proxy_links | sed '/^$/d')"
  [ -n "$current_links" ] || fail "Не удалось определить текущий VLESS в Podkop."

  working_links="$current_links"
  while :; do
    podkop_backup_candidate_menu "$working_links" || return 0

    if podkop_link_in_list "$BACKUP_SOURCE_VLESS" "$working_links"; then
      warn "Этот VLESS уже есть в Podkop, выбери другой."
      continue
    fi

    if [ -n "$working_links" ]; then
      working_links="$(printf "%s\n%s\n" "$working_links" "$BACKUP_SOURCE_VLESS" | sed '/^$/d')"
    else
      working_links="$BACKUP_SOURCE_VLESS"
    fi

    podkop_apply_urltest_links "$working_links"
    done_ "Резервный канал добавлен в Podkop через URLTest"
    podkop_print_active_urltest_links

    say "1) Добавить ещё резервный канал"
    say "2) Завершить"
    say "0) Назад"
    ask "Ввод (0-2)" PODKOP_BACKUP_MORE "2"
    case "$PODKOP_BACKUP_MORE" in
      1) ;;
      2) return 0 ;;
      0) return 0 ;;
      *) fail "Введи 0, 1 или 2" ;;
    esac
  done
}

patch_podkop_add_private_iface_only() {
  private_iface="${1:-$(podkop_private_iface)}"
  uciq get podkop.settings >/dev/null || uciq set podkop.settings='settings'
  if ! uci -q get podkop.settings.source_network_interfaces 2>/dev/null | grep -qw "$private_iface"; then
    uciq add_list podkop.settings.source_network_interfaces="$private_iface"
    uciq commit podkop
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
  fi
  done_ "Podkop: ${private_iface} добавлен в source_network_interfaces"
}
