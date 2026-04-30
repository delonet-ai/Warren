#!/bin/sh
# Warren main entrypoint: packages -> expand-root (reboot) -> podkop -> private access
# Designed for OpenWrt 24.10.x / 25.12.x on NanoPi R5S/R5C
# Usage (GitHub): wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh

set -e

TTY="${TTY:-/dev/tty}"
EXPAND_ROOT_URL="${EXPAND_ROOT_URL:-https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0}"
PODKOP_INSTALL_URL="${PODKOP_INSTALL_URL:-https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh}"
EXPAND_ROOT_SHA256="${EXPAND_ROOT_SHA256:-}"
PODKOP_INSTALL_SHA256="${PODKOP_INSTALL_SHA256:-}"
WARREN_LIB_BASE_URL="${WARREN_LIB_BASE_URL:-${BOOTSTRAP_LIB_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main/lib}}"
WARREN_ASSET_BASE_URL="${WARREN_ASSET_BASE_URL:-${BOOTSTRAP_ASSET_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main/assets}}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo ".")"
WARREN_DEV_DIR_DEFAULT="${SCRIPT_DIR}/.warren-dev"

migrate_legacy_file_if_missing() {
  legacy_path="$1"
  target_path="$2"
  [ -f "$legacy_path" ] || return 0
  [ -e "$target_path" ] && return 0
  mkdir -p "$(dirname "$target_path")" 2>/dev/null || true
  mv "$legacy_path" "$target_path" 2>/dev/null || cp "$legacy_path" "$target_path" 2>/dev/null || true
}

migrate_legacy_dir_if_missing() {
  legacy_path="$1"
  target_path="$2"
  [ -d "$legacy_path" ] || return 0
  [ -e "$target_path" ] && return 0
  mkdir -p "$(dirname "$target_path")" 2>/dev/null || true
  mv "$legacy_path" "$target_path" 2>/dev/null || cp -R "$legacy_path" "$target_path" 2>/dev/null || true
}

if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && [ -w /etc ] && [ -d /root ]; then
  WARREN_LEGACY_BASE_DIR="${WARREN_LEGACY_BASE_DIR:-/etc}"
  WARREN_LEGACY_LOG_DIR="${WARREN_LEGACY_LOG_DIR:-/root}"
  WARREN_BASE_DIR="${WARREN_BASE_DIR:-/etc/warren}"
  WARREN_LOG_DIR="${WARREN_LOG_DIR:-/root/warren}"
  STATE="${STATE:-${WARREN_BASE_DIR}/warren.state}"
  CONF="${CONF:-${WARREN_BASE_DIR}/warren.conf}"
  LOG="${LOG:-${WARREN_LOG_DIR}/warren.log}"
  LIB_CACHE_DIR="${LIB_CACHE_DIR:-/tmp/warren-lib}"
  ASSET_CACHE_DIR="${ASSET_CACHE_DIR:-/tmp/warren-assets}"
  AUTO_STATE_JSON="${AUTO_STATE_JSON:-/tmp/warren-runtime.json}"
  AUTO_STATE_STORE="${AUTO_STATE_STORE:-/tmp/warren-runtime.tsv}"
  mkdir -p "$WARREN_BASE_DIR" "$WARREN_LOG_DIR" || {
    printf "%s\n" "Не удалось создать каталоги Warren: $WARREN_BASE_DIR $WARREN_LOG_DIR" >&2
    exit 1
  }
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren.state" "$STATE"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren.conf" "$CONF"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren-tg-bot.conf" "${WARREN_BASE_DIR}/warren-tg-bot.conf"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren-vless-endpoints" "${WARREN_BASE_DIR}/warren-vless-endpoints"
  migrate_legacy_dir_if_missing "${WARREN_LEGACY_BASE_DIR}/vps" "${WARREN_BASE_DIR}/vps"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_LOG_DIR}/warren.log" "$LOG"
  migrate_legacy_dir_if_missing "${WARREN_LEGACY_LOG_DIR}/warren-diagnostics" "${WARREN_LOG_DIR}/warren-diagnostics"
else
  WARREN_DEV_DIR="${WARREN_DEV_DIR:-$WARREN_DEV_DIR_DEFAULT}"
  mkdir -p "$WARREN_DEV_DIR" || {
    printf "%s\n" "Не удалось создать каталог для локального режима: $WARREN_DEV_DIR" >&2
    exit 1
  }
  STATE="${STATE:-${WARREN_DEV_DIR}/warren.state}"
  CONF="${CONF:-${WARREN_DEV_DIR}/warren.conf}"
  LOG="${LOG:-${WARREN_DEV_DIR}/warren.log}"
  LIB_CACHE_DIR="${LIB_CACHE_DIR:-${WARREN_DEV_DIR}/lib-cache}"
  ASSET_CACHE_DIR="${ASSET_CACHE_DIR:-${WARREN_DEV_DIR}/asset-cache}"
  AUTO_STATE_JSON="${AUTO_STATE_JSON:-${WARREN_DEV_DIR}/warren-runtime.json}"
  AUTO_STATE_STORE="${AUTO_STATE_STORE:-${WARREN_DEV_DIR}/warren-runtime.tsv}"
fi

warren_die() {
  printf "%s\n" "$*" >&2
  exit 1
}

fetch_lib() {
  name="$1"
  local_path="$SCRIPT_DIR/lib/$name"
  system_path="/usr/lib/warren/lib/$name"
  use_local_libs="${WARREN_USE_LOCAL_LIBS:-}"

  case "$SCRIPT_DIR" in
    /tmp|/tmp/*)
      [ "$use_local_libs" = "1" ] || local_path=""
      ;;
  esac

  if [ -n "$local_path" ]; then
    if [ -r "$local_path" ]; then
      echo "$local_path"
      return 0
    fi
  fi

  if [ -r "$system_path" ]; then
    echo "$system_path"
    return 0
  fi

  mkdir -p "$LIB_CACHE_DIR" || warren_die "Не удалось создать каталог библиотек: $LIB_CACHE_DIR"
  cached_path="$LIB_CACHE_DIR/$name"
  wget -qO "$cached_path" "$WARREN_LIB_BASE_URL/$name" || warren_die "Не удалось скачать библиотеку: $name"
  echo "$cached_path"
}

fetch_asset() {
  name="$1"
  local_path="$SCRIPT_DIR/assets/$name"
  system_path="/usr/lib/warren/assets/$name"
  use_local_libs="${WARREN_USE_LOCAL_LIBS:-}"

  case "$SCRIPT_DIR" in
    /tmp|/tmp/*)
      [ "$use_local_libs" = "1" ] || local_path=""
      ;;
  esac

  if [ -n "$local_path" ] && [ -r "$local_path" ]; then
    echo "$local_path"
    return 0
  fi

  if [ -r "$system_path" ]; then
    echo "$system_path"
    return 0
  fi

  mkdir -p "$ASSET_CACHE_DIR" || warren_die "Не удалось создать каталог ассетов: $ASSET_CACHE_DIR"
  cached_path="$ASSET_CACHE_DIR/$name"
  wget -qO "$cached_path" "$WARREN_ASSET_BASE_URL/$name" || warren_die "Не удалось скачать ассет: $name"
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
source_lib amneziawg.sh
source_lib vps.sh
source_lib amnezia.sh
source_lib qos.sh
source_lib remote_admin.sh
source_lib usb_modem.sh
source_lib tg_bot.sh
source_lib diagnostics.sh
source_lib sni_checker.sh
source_lib luci.sh

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
  [ "$MODE" = "podkop_setup" ] || [ "$MODE" = "auto" ]
}

mode_is_private() {
  [ "$MODE" = "add_private" ]
}

show_mode_banner() {
  say ""
  case "$MODE" in
    auto)
      say "${YELLOW}INFO${NC}  Автоматический режим доводит маршрут до Podkop под ключ."
      say "Если есть готовые VPS-конфиги, предложу выбрать один. Если нет — можно сразу пройти через настройку VPS."
      ;;
    add_private|manage_private)
      say "${YELLOW}INFO${NC}  Amnezia Private использует AmneziaWG на интерфейсе awg0."
      ;;
    podkop_backup)
      say "${YELLOW}INFO${NC}  Режим резервного канала переведёт Podkop на URLTest с несколькими VLESS."
      ;;
    sni_checker)
      say "${YELLOW}INFO${NC}  SNI-checker подготовит и запустит на VPS read-only проверку кандидатов для Reality."
      say "3x-ui, Xray, firewall и конфиги трогаться не будут."
      ;;
  esac
}

mode_target_state() {
  case "$MODE" in
    basic) echo 75 ;;
    podkop_setup|auto) echo 90 ;;
    add_private) echo 120 ;;
    *) echo 0 ;;
  esac
}

mode_is_one_shot_service() {
  case "$MODE" in
    initialize|vps|podkop_backup|qos_private|remote_admin|usb_modem|tg_bot|diagnostics|diagnostics_emergency|manage_private|sni_checker)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prepare_auto_vless() {
  [ "$MODE" = "auto" ] || return 0

  if select_vps_report_for_podkop; then
    return 0
  fi

  warn "Не нашёл готовых VPS-отчётов в $(vps_reports_dir)."
  say "1) Настроить VPS сейчас и продолжить авторежим"
  say "2) Вставить VLESS вручную"
  ask "Выбор (1-2)" AUTO_VLESS_CHOICE "1"

  case "$AUTO_VLESS_CHOICE" in
    1)
      run_vps_flow
      REPORT_FILE="${REPORT_FILE:-$(vps_report_file)}"
      if [ -r "$REPORT_FILE" ]; then
        SELECTED_VPS_REPORT="$REPORT_FILE"
        conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
        runtime_state_set "selected_vps_report" "$SELECTED_VPS_REPORT"
      fi
      [ -n "${VLESS:-}" ] || VLESS="$(vps_report_vless_link "${SELECTED_VPS_REPORT:-}")"
      [ -n "${VLESS:-}" ] || fail "После настройки VPS не удалось получить VLESS для Podkop."
      conf_set VLESS "$VLESS"
      runtime_state_set "vless" "$VLESS"
      ;;
    2)
      ask "Вставь строку VLESS для Podkop (одной строкой)" VLESS "${VLESS:-}"
      [ -n "${VLESS:-}" ] || fail "VLESS пустой. Сначала настрой VPS или вставь ссылку вручную."
      conf_set VLESS "$VLESS"
      SELECTED_VPS_REPORT=""
      conf_set SELECTED_VPS_REPORT ""
      runtime_state_set "vless" "$VLESS"
      runtime_state_set "selected_vps_report" ""
      ;;
    *)
      fail "Введи 1 или 2"
      ;;
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
  case "$MODE" in
    podkop_backup)
      add_podkop_backup_channel
      ;;
    *)
      st="$(get_state)"
      [ "$st" -lt 80 ] && install_podkop && set_state 80
      [ "$st" -lt 90 ] && configure_podkop_full && set_state 90
      ;;
  esac
}

run_service_mode() {
  case "$MODE" in
    initialize) install_warren_luci_ui ;;
    vps) run_vps_flow ;;
    podkop_backup) add_podkop_backup_channel ;;
    sni_checker) run_sni_checker_flow ;;
    qos_private) run_qos_flow ;;
    remote_admin) run_remote_admin_flow ;;
    usb_modem) run_usb_modem_flow ;;
    tg_bot) run_tg_bot_flow ;;
    diagnostics) run_diagnostics_flow ;;
    diagnostics_emergency) DIAG_FORCE_FALLBACK=1 run_diagnostics_flow ;;
    manage_private) run_amnezia_manage_flow ;;
    *) return 1 ;;
  esac

  conf_set MODE ""
  cleanup_runtime_state
  exit 0
}

main() {
  if [ "${1:-}" = "--install-luci" ]; then
    MODE="initialize"
    install_warren_luci_ui
    exit 0
  fi

  if [ "${1:-}" = "--luci-run" ]; then
    MODE="${2:-}"
    [ -n "$MODE" ] || fail "Не задан режим Warren для LuCI"
    LUCI_VPS_HOST="${VPS_HOST:-}"
    LUCI_VPS_SSH_PORT="${VPS_SSH_PORT:-}"
    LUCI_VPS_ROOT_PASSWORD="${VPS_ROOT_PASSWORD:-}"
    LUCI_TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    LUCI_TG_BOT_CHAT_ID="${TG_BOT_CHAT_ID:-}"
    load_conf_if_exists || true
    [ -n "$LUCI_VPS_HOST" ] && VPS_HOST="$LUCI_VPS_HOST"
    [ -n "$LUCI_VPS_SSH_PORT" ] && VPS_SSH_PORT="$LUCI_VPS_SSH_PORT"
    [ -n "$LUCI_VPS_ROOT_PASSWORD" ] && VPS_ROOT_PASSWORD="$LUCI_VPS_ROOT_PASSWORD"
    [ -n "$LUCI_TG_BOT_TOKEN" ] && TG_BOT_TOKEN="$LUCI_TG_BOT_TOKEN"
    [ -n "$LUCI_TG_BOT_CHAT_ID" ] && TG_BOT_CHAT_ID="$LUCI_TG_BOT_CHAT_ID"
    conf_set MODE "$MODE"
    WARREN_LUCI_REQUEST=1
  fi

  if [ "${WARREN_LUCI_REQUEST:-}" = "1" ]; then
    load_conf_if_exists || true
  elif [ -f "$CONF" ]; then
    load_conf
    if mode_is_one_shot_service || ! should_resume_current_mode; then
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

  prepare_auto_vless

  run_service_mode || true

  if [ "$MODE" != "podkop_backup" ]; then
    run_basic_flow
  fi

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
