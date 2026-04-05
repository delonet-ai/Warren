#!/bin/sh
# Warren main entrypoint: packages -> expand-root (reboot) -> podkop -> private access
# Designed for OpenWrt 24.10.x on NanoPi R5S/R5C
# Usage (GitHub): wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh

set -e

STATE="/etc/warren.state"
CONF="/etc/warren.conf"
LOG="/root/warren.log"
TTY="/dev/tty"
EXPAND_ROOT_URL="${EXPAND_ROOT_URL:-https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0}"
PODKOP_INSTALL_URL="${PODKOP_INSTALL_URL:-https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh}"
EXPAND_ROOT_SHA256="${EXPAND_ROOT_SHA256:-}"
PODKOP_INSTALL_SHA256="${PODKOP_INSTALL_SHA256:-}"
WARREN_LIB_BASE_URL="${WARREN_LIB_BASE_URL:-${BOOTSTRAP_LIB_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main/lib}}"
LIB_CACHE_DIR="${LIB_CACHE_DIR:-/tmp/warren-lib}"
AUTO_STATE_JSON="${AUTO_STATE_JSON:-/tmp/warren-runtime.json}"
AUTO_STATE_STORE="${AUTO_STATE_STORE:-/tmp/warren-runtime.tsv}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo ".")"

warren_die() {
  printf "%s\n" "$*" >&2
  exit 1
}

fetch_lib() {
  name="$1"
  local_path="$SCRIPT_DIR/lib/$name"

  if [ -r "$local_path" ]; then
    echo "$local_path"
    return 0
  fi

  mkdir -p "$LIB_CACHE_DIR" || warren_die "Не удалось создать каталог библиотек: $LIB_CACHE_DIR"
  cached_path="$LIB_CACHE_DIR/$name"
  wget -qO "$cached_path" "$WARREN_LIB_BASE_URL/$name" || warren_die "Не удалось скачать библиотеку: $name"
  echo "$cached_path"
}

source_lib() {
  lib_path="$(fetch_lib "$1")"
  # shellcheck disable=SC1090
  . "$lib_path"
}

source_lib common.sh
source_lib ui.sh
source_lib state.sh
source_lib basic.sh
source_lib podkop.sh
source_lib wireguard.sh
source_lib vps.sh
source_lib amnezia.sh
source_lib qos.sh
source_lib remote_admin.sh
source_lib usb_modem.sh

expand_root_prep() {
  cd /root
  rm -f /root/expand-root.sh 2>/dev/null || true
  download_file "$EXPAND_ROOT_URL" /root/expand-root.sh "$EXPAND_ROOT_SHA256" "EXPAND_ROOT"
  sh ./expand-root.sh || fail "expand-root prep script завершился с ошибкой"
  [ -f /etc/uci-defaults/70-rootpt-resize ] || fail "Не найден /etc/uci-defaults/70-rootpt-resize после подготовки expand-root."
  chmod +x /etc/uci-defaults/70-rootpt-resize 2>/dev/null || true
  done_ "Подготовлен expand-root (uci-defaults/70-rootpt-resize готов)"
}

expand_root_run_and_reboot() {
  sh /etc/uci-defaults/70-rootpt-resize || true
  set_state 60
  done_ "Запущен expand-root. Сейчас будет ребут. После загрузки запусти скрипт снова."
  reboot
  fail "Команда reboot не выполнилась"
}

mode_is_podkop() {
  [ "$MODE" = "podkop" ] || [ "$MODE" = "podkop_private" ] || [ "$MODE" = "auto" ]
}

mode_is_private() {
  [ "$MODE" = "podkop_private" ] || [ "$MODE" = "add_private" ]
}

show_mode_banner() {
  say ""
  case "$MODE" in
    auto)
      say "${YELLOW}INFO${NC}  Автоматический режим пока в переходном состоянии."
      say "Сейчас он ещё не умеет настраивать VPS сам, но временный runtime JSON уже готов для следующего этапа."
      ;;
    podkop_private|add_private|manage_private)
      say "${YELLOW}INFO${NC}  Название уже про Amnezia Private, но backend пока ещё временно WireGuard."
      ;;
  esac
}

mode_target_state() {
  case "$MODE" in
    basic) echo 75 ;;
    podkop|auto) echo 90 ;;
    podkop_private|add_private) echo 120 ;;
    *) echo 0 ;;
  esac
}

should_resume_current_mode() {
  target="$(mode_target_state)"
  st="$(get_state)"
  [ "$target" -gt 0 ] && [ "$st" -gt 0 ] && [ "$st" -lt "$target" ]
}

run_basic_flow() {
  st="$(get_state)"
  log "state=$st mode=$MODE"

  print_progress

  [ "$st" -lt 10 ] && check_openwrt && set_state 10
  [ "$st" -lt 20 ] && check_inet && set_state 20
  [ "$st" -lt 30 ] && sync_time && set_state 30

  if [ "$st" -lt 40 ]; then
    if install_full_pkg_list; then
      set_state 40
    else
      warn "Установка пакетов упала (часто из-за места). Всё равно попробую expand-root, затем повторю установку."
      set_state 35
    fi
  fi

  [ "$st" -lt 45 ] && check_space_overlay && set_state 45

  if [ "$st" -lt 50 ]; then
    if overlay_report_and_ask_expand; then
      expand_root_prep
      set_state 50
    else
      done_ "Пропускаю expand-root по выбору пользователя"
      set_state 75
    fi
  fi

  [ "$st" -lt 60 ] && expand_root_run_and_reboot
  [ "$st" -lt 70 ] && install_full_pkg_list && set_state 70
  [ "$st" -lt 75 ] && check_space_overlay && set_state 75
}

run_podkop_flow() {
  st="$(get_state)"
  [ "$st" -lt 80 ] && install_podkop && set_state 80
  [ "$st" -lt 90 ] && configure_podkop_full && set_state 90
}

run_service_mode() {
  case "$MODE" in
    vps) run_vps_flow ;;
    qos_private) run_qos_flow ;;
    remote_admin) run_remote_admin_flow ;;
    usb_modem) run_usb_modem_flow ;;
    manage_private) run_amnezia_manage_flow ;;
    *) return 1 ;;
  esac

  cleanup_runtime_state
  exit 0
}

main() {
  if [ -f "$CONF" ]; then
    load_conf
    if ! should_resume_current_mode; then
      menu
      load_conf
    fi
  else
    menu
    load_conf
  fi

  clear_terminal
  print_banner
  show_mode_banner

  run_service_mode || true

  run_basic_flow

  if mode_is_podkop; then
    run_podkop_flow
  fi

  if mode_is_private; then
    run_amnezia_private_flow
  fi

  cleanup_runtime_state
  done_ "Готово. State=$(get_state). Логи: $LOG"
  say "Если был ребут — просто запусти тот же скрипт снова, он продолжит."
}

main
