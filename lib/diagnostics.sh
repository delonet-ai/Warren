warren_diag_ts() {
  date +'%Y%m%d-%H%M%S'
}

warren_diag_log_dir() {
  printf "%s\n" "${WARREN_DIAG_LOG_DIR:-${WARREN_LOG_DIR:-/root}/warren-diagnostics}"
}

warren_diag_line() {
  printf "%s\n" "$*" >> "$DIAG_LOG"
}

warren_diag_section() {
  warren_diag_line ""
  warren_diag_line "===== $* ====="
}

warren_diag_cmd() {
  title="$1"
  shift

  warren_diag_section "$title"
  warren_diag_line "# $*"
  if "$@" >> "$DIAG_LOG" 2>&1; then
    rc=0
  else
    rc="$?"
  fi
  warren_diag_line "# exit=$rc"
  return 0
}

warren_diag_ok() {
  DIAG_OK_COUNT=$((DIAG_OK_COUNT + 1))
  warren_diag_line "OK: $*"
}

warren_diag_bad() {
  DIAG_BAD_COUNT=$((DIAG_BAD_COUNT + 1))
  warren_diag_line "BAD: $*"
  DIAG_ISSUES="${DIAG_ISSUES}${DIAG_ISSUES:+
}- $*"
}

warren_diag_has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

warren_diag_first_wan_gateway() {
  ip route show default 2>/dev/null | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}'
}

warren_diag_proxy_links() {
  proxy_type="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || true)"

  case "$proxy_type" in
    urltest)
      uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
      ;;
    selector)
      uci -q get podkop.main.selector_proxy_links 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
      ;;
    *)
      uci -q get podkop.main.proxy_string 2>/dev/null | sed '/^$/d'
      ;;
  esac
}

warren_diag_parse_proxy_endpoint() {
  link="$1"
  DIAG_PROXY_HOST=""
  DIAG_PROXY_PORT=""

  [ -n "$link" ] || return 0
  authority="$(printf "%s" "$link" | sed -n 's|^[a-zA-Z0-9+.-]*://[^@]*@\([^/?#]*\).*|\1|p')"
  [ -n "$authority" ] || authority="$(printf "%s" "$link" | sed -n 's|^[a-zA-Z0-9+.-]*://\([^/?#]*\).*|\1|p')"
  [ -n "$authority" ] || return 0

  DIAG_PROXY_HOST="$(printf "%s" "$authority" | sed 's/^\[\([^]]*\)\].*/\1/; s/:.*$//')"
  DIAG_PROXY_PORT="$(printf "%s" "$authority" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p')"
}

warren_diag_tcp_check() {
  host="$1"
  port="$2"
  timeout="${3:-3}"
  tmp="/tmp/warren-diag-curl.$$"

  [ -n "$host" ] && [ -n "$port" ] || return 2

  if warren_diag_has_cmd curl; then
    if [ "$port" = "443" ]; then
      scheme="https"
      curl_tls="-k"
    else
      scheme="http"
      curl_tls=""
    fi

    if curl $curl_tls -vIs --connect-timeout "$timeout" --max-time "$timeout" "${scheme}://${host}:${port}/" > "$tmp" 2>&1; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi

    if grep -Eqi 'Connected to|Received HTTP/0\.9|Empty reply from server|invalid SSL record|wrong version number|first record does not look like a TLS handshake' "$tmp" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi

    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  if warren_diag_has_cmd nc && nc -h 2>&1 | grep -q -- '-z'; then
    nc -w "$timeout" -z "$host" "$port" >/dev/null 2>&1
    return "$?"
  fi

  return 127
}

warren_diag_check_ping() {
  label="$1"
  host="$2"
  [ -n "$host" ] || {
    warren_diag_bad "$label: адрес не найден"
    return 0
  }

  if ping -c 2 -W 2 "$host" >/dev/null 2>&1; then
    warren_diag_ok "$label: ping $host"
  else
    warren_diag_bad "$label: ping $host не проходит"
  fi
}

warren_diag_check_dns() {
  label="$1"
  resolver="$2"
  domain="$3"

  if nslookup "$domain" "$resolver" >/dev/null 2>&1; then
    warren_diag_ok "$label: DNS $domain через $resolver"
  else
    warren_diag_bad "$label: DNS $domain через $resolver не отвечает"
  fi
}

warren_diag_check_time() {
  if warren_time_sane; then
    warren_diag_ok "System time: корректное время для TLS ($(date +'%F %T %z'))"
  else
    warren_diag_bad "System time: неверное время для TLS ($(date +'%F %T %z')); Podkop/GitHub/HTTPS могут падать"
  fi
}

warren_diag_check_tcp() {
  label="$1"
  host="$2"
  port="$3"

  if [ -z "$host" ] || [ -z "$port" ]; then
    warren_diag_bad "$label: host/port не определены"
    return 0
  fi

  if warren_diag_tcp_check "$host" "$port" 3; then
    rc=0
  else
    rc="$?"
  fi
  case "$rc" in
    0) warren_diag_ok "$label: TCP $host:$port доступен" ;;
    127) warren_diag_bad "$label: нет nc/curl для TCP-проверки $host:$port" ;;
    *) warren_diag_bad "$label: TCP $host:$port не доступен" ;;
  esac
}

warren_diag_check_service() {
  service="$1"
  if [ -x "/etc/init.d/$service" ]; then
    if "/etc/init.d/$service" status >/dev/null 2>&1; then
      warren_diag_ok "service $service: запущен"
    else
      warren_diag_bad "service $service: не выглядит запущенным"
    fi
  else
    warren_diag_bad "service $service: init-скрипт не найден"
  fi
}

warren_diag_check_proxy_engine() {
  if [ -x /etc/init.d/sing-box ]; then
    warren_diag_check_service sing-box
    return 0
  fi
  if pgrep -x sing-box >/dev/null 2>&1 || pgrep -f '/usr/bin/sing-box' >/dev/null 2>&1; then
    warren_diag_ok "proxy engine sing-box: процесс запущен"
    return 0
  fi
  if [ -x /etc/init.d/xray ]; then
    warren_diag_check_service xray
    return 0
  fi
  if pgrep -x xray >/dev/null 2>&1 || pgrep -f '/usr/bin/xray' >/dev/null 2>&1; then
    warren_diag_ok "proxy engine xray: процесс запущен"
    return 0
  fi
  warren_diag_bad "proxy engine: не найден запущенный sing-box/xray"
}

warren_diag_check_podkop_runtime() {
  if ! uci -q get podkop.main >/dev/null 2>&1; then
    warren_diag_bad "Podkop: секция podkop.main не найдена"
    return 0
  fi

  if [ -x /etc/init.d/podkop ] && /etc/init.d/podkop status >/dev/null 2>&1; then
    warren_diag_ok "Podkop: init status запущен"
    return 0
  fi

  if { pgrep -x sing-box >/dev/null 2>&1 || pgrep -f '/usr/bin/sing-box' >/dev/null 2>&1; } \
    && ip rule show 2>/dev/null | grep -q 'lookup podkop'; then
    warren_diag_ok "Podkop: UCI, sing-box и routing rule активны"
    return 0
  fi

  warren_diag_bad "Podkop: runtime не выглядит активным"
}

warren_diag_check_podkop_defaults() {
  dns_server="$(uci -q get podkop.settings.dns_server 2>/dev/null || true)"
  bootstrap_dns="$(uci -q get podkop.settings.bootstrap_dns_server 2>/dev/null || true)"
  proxy_type="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || true)"

  if [ "$dns_server" = "9.9.9.9" ]; then
    warren_diag_ok "Podkop DNS: основной DNS 9.9.9.9"
  else
    warren_diag_bad "Podkop DNS: основной DNS ${dns_server:-<unset>}, ожидается 9.9.9.9"
  fi

  if [ "$bootstrap_dns" = "77.88.8.8" ]; then
    warren_diag_ok "Podkop DNS: bootstrap DNS 77.88.8.8"
  else
    warren_diag_bad "Podkop DNS: bootstrap DNS ${bootstrap_dns:-<unset>}, ожидается 77.88.8.8"
  fi

  case "$proxy_type" in
    url|urltest|selector)
      warren_diag_ok "Podkop mode: $proxy_type"
      ;;
    *)
      warren_diag_bad "Podkop mode: ${proxy_type:-<unset>} не похож на рабочий proxy mode"
      ;;
  esac
}

warren_diag_capture_snapshot() {
  phase="$1"
  DIAG_OK_COUNT=0
  DIAG_BAD_COUNT=0
  DIAG_ISSUES=""

  warren_diag_section "SNAPSHOT $phase"
  warren_diag_line "time=$(date +'%F %T %z')"
  warren_diag_line "hostname=$(hostname 2>/dev/null || true)"
  warren_diag_line "mode=${MODE:-unknown}"

  proxy_links_file="/tmp/warren-diag-proxies.$$"
  warren_diag_proxy_links > "$proxy_links_file" 2>/dev/null || true
  proxy_link="$(sed '/^$/d' "$proxy_links_file" 2>/dev/null | head -n1)"
  proxy_count="$(sed '/^$/d' "$proxy_links_file" 2>/dev/null | wc -l | tr -d ' ')"
  warren_diag_parse_proxy_endpoint "$proxy_link"
  wan_gw="$(warren_diag_first_wan_gateway)"

  warren_diag_line "wan_gateway=${wan_gw:-unknown}"
  warren_diag_line "proxy_count=${proxy_count:-0}"
  warren_diag_line "proxy_host=${DIAG_PROXY_HOST:-unknown}"
  warren_diag_line "proxy_port=${DIAG_PROXY_PORT:-unknown}"
  warren_diag_line "vps_host=${VPS_HOST:-unknown}"
  warren_diag_line "vps_ssh_port=${VPS_SSH_PORT:-22}"

  warren_diag_cmd "OpenWrt release" sh -c '. /etc/openwrt_release 2>/dev/null; echo DISTRIB_RELEASE=$DISTRIB_RELEASE; echo DISTRIB_TARGET=$DISTRIB_TARGET'
  warren_diag_cmd "UCI podkop" sh -c 'uci show podkop 2>&1'
  warren_diag_cmd "Interfaces" sh -c 'ip addr show 2>&1'
  warren_diag_cmd "Routes main" sh -c 'ip route show table main 2>&1'
  warren_diag_cmd "Rules" sh -c 'ip rule show 2>&1'
  warren_diag_cmd "Routes all" sh -c 'ip route show table all 2>&1'
  warren_diag_cmd "DNS config" sh -c 'cat /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf 2>&1'
  warren_diag_cmd "Listeners" sh -c 'ss -lntup 2>&1'
  warren_diag_cmd "Podkop log" sh -c 'logread -e podkop 2>&1 | tail -n 160'
  warren_diag_cmd "sing-box log" sh -c 'logread -e sing-box 2>&1 | tail -n 160'
  warren_diag_cmd "dnsmasq log" sh -c 'logread -e dnsmasq 2>&1 | tail -n 120'
  warren_diag_cmd "nft podkop/tproxy rules" sh -c 'nft list ruleset 2>&1 | grep -Ei "podkop|sing|tproxy|mark|dns|redirect" -C 3'

  warren_diag_section "ACTIVE CHECKS $phase"
  warren_diag_check_time
  warren_diag_check_podkop_runtime
  warren_diag_check_podkop_defaults
  warren_diag_check_proxy_engine

  warren_diag_check_ping "WAN gateway" "$wan_gw"
  warren_diag_check_ping "Public IP 9.9.9.9" "9.9.9.9"
  warren_diag_check_ping "Public IP 8.8.8.8" "8.8.8.8"
  warren_diag_check_dns "Local resolver" "127.0.0.1" "ya.ru"
  warren_diag_check_dns "External resolver" "77.88.8.8" "ya.ru"
  warren_diag_check_dns "External resolver" "9.9.9.9" "google.com"
  warren_diag_check_tcp "OpenWrt downloads HTTPS" "downloads.openwrt.org" "443"

  if [ "${proxy_count:-0}" -gt 0 ]; then
    proxy_index=1
    while IFS= read -r checked_proxy_link; do
      [ -n "$checked_proxy_link" ] || continue
      warren_diag_parse_proxy_endpoint "$checked_proxy_link"
      warren_diag_check_ping "VLESS host #$proxy_index" "$DIAG_PROXY_HOST"
      warren_diag_check_tcp "VLESS endpoint #$proxy_index" "$DIAG_PROXY_HOST" "$DIAG_PROXY_PORT"
      proxy_index=$((proxy_index + 1))
    done < "$proxy_links_file"
  else
    warren_diag_bad "VLESS endpoint: не удалось извлечь host из Podkop"
  fi
  rm -f "$proxy_links_file" 2>/dev/null || true

  if [ -n "${VPS_HOST:-}" ]; then
    warren_diag_check_ping "Configured VPS_HOST" "$VPS_HOST"
    warren_diag_check_tcp "Configured VPS SSH" "$VPS_HOST" "${VPS_SSH_PORT:-22}"
  else
    warren_diag_line "INFO: VPS_HOST в Warren не задан, SSH-проверяю VLESS host если он есть"
    if [ -n "${DIAG_PROXY_HOST:-}" ]; then
      warren_diag_check_tcp "VLESS host SSH" "$DIAG_PROXY_HOST" "${VPS_SSH_PORT:-22}"
    fi
  fi

  warren_diag_line ""
  warren_diag_line "SUMMARY $phase: ok=$DIAG_OK_COUNT bad=$DIAG_BAD_COUNT"

  DIAG_LAST_OK="$DIAG_OK_COUNT"
  DIAG_LAST_BAD="$DIAG_BAD_COUNT"
  DIAG_LAST_ISSUES="$DIAG_ISSUES"
}

warren_diag_apply_dns_fallback() {
  warren_diag_section "APPLY DNS FALLBACK"
  DIAG_OLD_DNS_TYPE="$(uci -q get podkop.settings.dns_type 2>/dev/null || true)"
  DIAG_OLD_DNS_SERVER="$(uci -q get podkop.settings.dns_server 2>/dev/null || true)"
  DIAG_OLD_BOOTSTRAP_DNS_SERVER="$(uci -q get podkop.settings.bootstrap_dns_server 2>/dev/null || true)"

  warren_diag_line "old_dns_type=${DIAG_OLD_DNS_TYPE:-<unset>}"
  warren_diag_line "old_dns_server=${DIAG_OLD_DNS_SERVER:-<unset>}"
  warren_diag_line "old_bootstrap_dns_server=${DIAG_OLD_BOOTSTRAP_DNS_SERVER:-<unset>}"

  if ! uci -q get podkop.main >/dev/null 2>&1; then
    warren_diag_line "DNS fallback skipped: podkop.main not found"
    DIAG_DNS_FALLBACK_APPLIED=0
    return 0
  fi

  uci -q get podkop.settings >/dev/null 2>&1 || uci set podkop.settings='settings'
  uci set podkop.settings.dns_type='udp'
  uci set podkop.settings.dns_server='77.88.8.8'
  uci set podkop.settings.bootstrap_dns_server='77.88.8.8'
  if ! uci commit podkop; then
    warren_diag_line "DNS fallback failed: uci commit podkop"
    DIAG_DNS_FALLBACK_APPLIED=0
    return 0
  fi
  DIAG_DNS_FALLBACK_APPLIED=1
  /etc/init.d/podkop restart >> "$DIAG_LOG" 2>&1 || true
  sleep 3
}

warren_diag_restore_dns_settings() {
  warren_diag_section "RESTORE DNS SETTINGS"

  if [ "${DIAG_DNS_FALLBACK_APPLIED:-0}" != "1" ]; then
    warren_diag_line "Restore skipped: DNS fallback was not applied"
    return 0
  fi

  uci -q get podkop.settings >/dev/null 2>&1 || uci set podkop.settings='settings'

  if [ -n "${DIAG_OLD_DNS_TYPE:-}" ]; then
    uci set podkop.settings.dns_type="$DIAG_OLD_DNS_TYPE"
  else
    uci -q delete podkop.settings.dns_type >/dev/null 2>&1 || true
  fi

  if [ -n "${DIAG_OLD_DNS_SERVER:-}" ]; then
    uci set podkop.settings.dns_server="$DIAG_OLD_DNS_SERVER"
  else
    uci -q delete podkop.settings.dns_server >/dev/null 2>&1 || true
  fi

  if [ -n "${DIAG_OLD_BOOTSTRAP_DNS_SERVER:-}" ]; then
    uci set podkop.settings.bootstrap_dns_server="$DIAG_OLD_BOOTSTRAP_DNS_SERVER"
  else
    uci -q delete podkop.settings.bootstrap_dns_server >/dev/null 2>&1 || true
  fi

  if uci commit podkop; then
    warren_diag_line "DNS settings restored"
  else
    warren_diag_line "DNS restore failed: uci commit podkop"
    return 0
  fi

  /etc/init.d/podkop restart >> "$DIAG_LOG" 2>&1 || true
  sleep 3
}

run_diagnostics_flow() {
  load_conf_if_exists || true

  mkdir -p "$(warren_diag_log_dir)" 2>/dev/null || fail "Не удалось создать каталог логов диагностики"
  DIAG_LOG="$(warren_diag_log_dir)/warren-diagnostics-$(warren_diag_ts).log"
  : > "$DIAG_LOG" || fail "Не удалось создать лог диагностики: $DIAG_LOG"

  say ""
  info "Запускаю диагностику штатной работы. Лог: $DIAG_LOG"
  warren_diag_capture_snapshot "before"

  say ""
  say "Диагностика: OK=$DIAG_LAST_OK, проблемы=$DIAG_LAST_BAD"
  if [ "${DIAG_FORCE_FALLBACK:-0}" = "1" ] || [ "$DIAG_LAST_BAD" -gt 0 ]; then
    say ""
    if [ "$DIAG_LAST_BAD" -gt 0 ]; then
      say "Кратко по проблемам:"
      printf "%s\n" "$DIAG_LAST_ISSUES" | sed '/^$/d' | sed 's/^/  /'
    else
      say "Аварийный режим запрошен вручную: применяю DNS-fallback и повторяю проверку."
    fi
    say ""
    if [ "${DIAG_FORCE_FALLBACK:-0}" = "1" ]; then
      DIAG_FIX_CHOICE="y"
    else
      ask "Применить диагностический DNS-fallback Podkop и повторить проверку? (y/n)" DIAG_FIX_CHOICE "y"
    fi
    case "$DIAG_FIX_CHOICE" in
      y|Y)
        info "Меняю DNS Podkop на UDP 77.88.8.8, перезапускаю только Podkop и повторяю проверки."
        warren_diag_apply_dns_fallback
        warren_diag_capture_snapshot "after_dns_fallback"
        say ""
        say "После DNS-fallback: OK=$DIAG_LAST_OK, проблемы=$DIAG_LAST_BAD"
        if [ "$DIAG_LAST_BAD" -gt 0 ]; then
          say "Оставшиеся проблемы:"
          printf "%s\n" "$DIAG_LAST_ISSUES" | sed '/^$/d' | sed 's/^/  /'
        fi
        info "Возвращаю DNS-настройки Podkop как были до диагностики."
        warren_diag_restore_dns_settings
        ;;
      n|N)
        warren_diag_line ""
        warren_diag_line "User skipped DNS fallback."
        ;;
      *)
        warn "Непонятный ответ, fallback пропущен."
        warren_diag_line ""
        warren_diag_line "DNS fallback skipped: invalid answer $DIAG_FIX_CHOICE"
        ;;
    esac
  fi

  done_ "Диагностика завершена. Лог: $DIAG_LOG"
}
