WARREN_WATCHDOG_BIN="${WARREN_WATCHDOG_BIN:-/usr/libexec/warren/warren-watchdog}"
WARREN_WATCHDOG_INIT="${WARREN_WATCHDOG_INIT:-/etc/init.d/warren-watchdog}"
WARREN_WATCHDOG_CONF="${WARREN_WATCHDOG_CONF:-/etc/warren/warren-watchdog.conf}"
WARREN_WATCHDOG_STATE="${WARREN_WATCHDOG_STATE:-/etc/warren/warren-watchdog.state}"

watchdog_write_worker() {
  mkdir -p "$(dirname "$WARREN_WATCHDOG_BIN")" "$(dirname "$WARREN_WATCHDOG_STATE")" ||
    fail "Не удалось создать каталоги Podkop Watchdog"
  podkop_health_install
  warren_install_payload warren-watchdog "$WARREN_WATCHDOG_BIN"
  chmod 755 "$WARREN_WATCHDOG_BIN" || fail "Не удалось сделать Watchdog executable"
}

watchdog_write_init() {
  warren_install_payload warren-watchdog.init "$WARREN_WATCHDOG_INIT"
  chmod 755 "$WARREN_WATCHDOG_INIT" || fail "Не удалось установить init script Watchdog"
}

watchdog_install() {
  [ -x /etc/init.d/podkop ] || fail "Podkop Watchdog требует установленный Podkop"
  watchdog_write_worker
  watchdog_write_init
  if [ ! -r "$WARREN_WATCHDOG_CONF" ]; then
    {
      printf "WARREN_WATCHDOG_INTERVAL=60\n"
      printf "WARREN_WATCHDOG_RESTART_DELAY=5\n"
      printf "WARREN_WATCHDOG_STABLE_WINDOW=600\n"
    } > "$WARREN_WATCHDOG_CONF" || fail "Не удалось записать Watchdog config"
    chmod 600 "$WARREN_WATCHDOG_CONF" 2>/dev/null || true
  fi
}

watchdog_enable() {
  watchdog_install
  "$WARREN_WATCHDOG_INIT" enable
  "$WARREN_WATCHDOG_INIT" restart
  done_ "Podkop Watchdog включён"
}

watchdog_disable() {
  [ -x "$WARREN_WATCHDOG_INIT" ] || return 0
  "$WARREN_WATCHDOG_INIT" stop >/dev/null 2>&1 || true
  "$WARREN_WATCHDOG_INIT" disable >/dev/null 2>&1 || true
  done_ "Podkop Watchdog выключен"
}

watchdog_reset() {
  watchdog_install
  "$WARREN_WATCHDOG_BIN" reset
  "$WARREN_WATCHDOG_INIT" restart >/dev/null 2>&1 || true
  done_ "Счётчик Podkop Watchdog сброшен"
}

watchdog_status() {
  enabled=no
  running=no
  [ -x "$WARREN_WATCHDOG_INIT" ] && "$WARREN_WATCHDOG_INIT" enabled && enabled=yes
  [ -x "$WARREN_WATCHDOG_INIT" ] && "$WARREN_WATCHDOG_INIT" running && running=yes
  printf "ENABLED=%s\nRUNNING=%s\n" "$enabled" "$running"
  if [ -x "$WARREN_WATCHDOG_BIN" ]; then
    "$WARREN_WATCHDOG_BIN" status
  else
    printf "%s\n" "STATUS=not-installed" "LAST_CHECK=0" "LAST_RESTART=0" \
      "RESTART_COUNT=0" "FAILURE_COUNT=0" "BACKOFF_UNTIL=0" "LAST_REASON=not-installed"
  fi
}

watchdog_cli() {
  case "${1:-status}" in
    status) watchdog_status ;;
    install|enable) watchdog_enable ;;
    disable) watchdog_disable ;;
    reset) watchdog_reset ;;
    run-once)
      watchdog_install
      "$WARREN_WATCHDOG_BIN" run-once
      ;;
    *) fail "Usage: warren --watchdog status|enable|disable|reset|run-once" ;;
  esac
}
