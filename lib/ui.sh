clear_terminal() {
  { [ -w "$TTY" ] && printf '\033[2J\033[H' > "$TTY"; } 2>/dev/null || printf '\033[2J\033[H'
}

print_banner() {
  say ""
  say "╔══════════════════════════════════════════════════════════════╗"
  say "║                         Warren Setup                         ║"
  say "╠══════════════════════════════════════════════════════════════╣"
  say "║ Этот скрипт с любовью разработал для тебя delonet-ai.         ║"
  say "║ Просто следуй шагам. Если что-то пошло не так —               ║"
  say "║ перезапускай скрипт. У тебя все получится 💪                  ║"
  say "╚══════════════════════════════════════════════════════════════╝"
  say "Версия Warren: ${GREEN}${WARREN_VERSION:-unknown}${NC}"
  say ""
  say "${YELLOW}ВАЖНО${NC}  После любого ребута или обрыва просто запусти одной командой: ${GREEN}warren${NC}"
  say "Путь конфигов VPS: ${GREEN}/etc/warren/vps/reports${NC}"
  say ""
}

progress_stage() {
  st="$1"
  if [ "$st" -lt 30 ]; then
    echo 0
  elif [ "$st" -lt 40 ]; then
    echo 1
  elif [ "$st" -lt 50 ]; then
    echo 2
  elif [ "$st" -lt 60 ]; then
    echo 3
  elif [ "$st" -lt 75 ]; then
    echo 4
  elif [ "$st" -lt 80 ]; then
    echo 5
  elif [ "$st" -lt 85 ]; then
    echo 6
  elif [ "$st" -lt 90 ]; then
    echo 7
  elif [ "$st" -lt 95 ]; then
    echo 8
  elif [ "$st" -lt 100 ]; then
    echo 9
  elif [ "$st" -lt 110 ]; then
    echo 10
  else
    echo 11
  fi
}

basic_progress_stage() {
  st="$1"
  if [ "$st" -lt 10 ]; then
    echo 0
  elif [ "$st" -lt 20 ]; then
    echo 1
  elif [ "$st" -lt 30 ]; then
    echo 2
  elif [ "$st" -lt 40 ]; then
    echo 3
  elif [ "$st" -lt 45 ]; then
    echo 4
  elif [ "$st" -lt 50 ]; then
    echo 5
  elif [ "$st" -lt 60 ]; then
    echo 6
  elif [ "$st" -lt 70 ]; then
    echo 7
  else
    echo 8
  fi
}

_stage_line() {
  idx="$1"
  cur="$2"
  title="$3"

  if [ "$idx" -lt "$cur" ]; then
    say "  ${GREEN}✅${NC} $title"
  elif [ "$idx" -eq "$cur" ]; then
    say "  ${YELLOW}⏳${NC} $title"
  else
    say "  ⬜ $title"
  fi
}

print_progress() {
  st="$(get_state)"
  cur="$(progress_stage "$st")"
  mode_label="${MODE:-}"

  say ""
  say "┌──────────────────────── Прогресс ────────────────────────────┐"
  if [ "$mode_label" = "basic" ]; then
    cur="$(basic_progress_stage "$st")"
    _stage_line 0 "$cur" "Preflight: версия OpenWrt"
    _stage_line 1 "$cur" "Preflight: интернет"
    _stage_line 2 "$cur" "Preflight: время / TLS"
    _stage_line 3 "$cur" "Установка пакетов (24 opkg / 25 apk)"
    _stage_line 4 "$cur" "Проверка overlay"
    _stage_line 5 "$cur" "Подготовка expand-root"
    _stage_line 6 "$cur" "Expand-root (resize → reboot)"
    _stage_line 7 "$cur" "Пакеты после reboot"
    _stage_line 8 "$cur" "Финальная проверка места"
    say "└──────────────────────────────────────────────────────────────┘"
    say "State: $st"
    say ""
    return 0
  fi

  _stage_line 0 "$cur" "Preflight (версия / интернет / время)"
  _stage_line 1 "$cur" "Установка пакетов (полный список)"
  _stage_line 2 "$cur" "Проверка места / подготовка expand-root"
  _stage_line 3 "$cur" "Expand-root (resize → reboot)"
  _stage_line 4 "$cur" "Пакеты после resize + проверка места"

  case "$mode_label" in
    basic)
      ;;
    auto)
      _stage_line 5 "$cur" "Установка UI Warren в LuCI"
      _stage_line 6 "$cur" "Источник proxy-конфига (VPS/отчёт/ссылка)"
      _stage_line 7 "$cur" "Установка Podkop"
      _stage_line 8 "$cur" "Настройка Podkop"
      _stage_line 9 "$cur" "Финальный отчёт и текущий конфиг"
      ;;
    add_private)
      _stage_line 5 "$cur" "Установка UI Warren в LuCI"
      _stage_line 6 "$cur" "Источник proxy-конфига (VPS/отчёт/ссылка)"
      _stage_line 7 "$cur" "Установка Podkop"
      _stage_line 8 "$cur" "Настройка Podkop"
      _stage_line 9 "$cur" "Финальный отчёт и текущий конфиг"
      _stage_line 10 "$cur" "Private access (сервер)"
      _stage_line 11 "$cur" "Private clients + QR"
      ;;
    *)
      _stage_line 5 "$cur" "Установка UI Warren в LuCI"
      _stage_line 6 "$cur" "Источник proxy-конфига (VPS/отчёт/ссылка)"
      _stage_line 7 "$cur" "Установка Podkop"
      _stage_line 8 "$cur" "Настройка Podkop"
      ;;
  esac

  say "└──────────────────────────────────────────────────────────────┘"
  say "State: $st"
  say ""
}

ask() {
  prompt="$1"
  var="$2"
  def="${3:-}"

  if { [ -r "$TTY" ] && [ -w "$TTY" ] && : > "$TTY"; } 2>/dev/null; then
    [ -n "$def" ] && printf "%s [%s]: " "$prompt" "$def" > "$TTY" || printf "%s: " "$prompt" > "$TTY"
    if ! IFS= read -r ans < "$TTY"; then
      ans=""
    fi
  else
    [ -n "$def" ] && printf "%s [%s]: " "$prompt" "$def" || printf "%s: " "$prompt"
    IFS= read -r ans || ans=""
  fi

  [ -z "$ans" ] && ans="$def"
  eval "$var=$(quote_sh "$ans")"
}

podkop_submenu() {
  say ""
  say "Podkop:"
  say "1) Стандартная настройка"
  say "2) Добавить резервный канал"
  say "0) Назад"
  ask "Ввод (0-2)" PODKOP_MENU_CHOICE "1"

  case "$PODKOP_MENU_CHOICE" in
    1) MODE="podkop_setup" ;;
    2) MODE="podkop_backup" ;;
    0)
      menu
      return 0
      ;;
    *)
      fail "Неверный выбор: $PODKOP_MENU_CHOICE"
      ;;
  esac
}

auto_show_requirements() {
  say ""
  say "Полный авторежим выполнит:"
  say "1) Базовые настройки роутера"
  say "2) Установку UI Warren в LuCI"
  say "3) Подготовку источника proxy-конфига для Podkop"
  say "4) Установку и настройку Podkop"
  say "5) Финальный отчёт с текущим конфигом"
  say ""
  say "Что важно заранее:"
  say "- Во время базовой настройки Warren автоматически выполнит expand-root и перезагрузит роутер."
  say "- После ребута просто снова запусти 'warren' — сценарий продолжится."
  say "- До старта нужно сразу подготовить все данные, которые понадобятся дальше."
  say ""
  say "Нужно иметь на руках один из вариантов для Podkop:"
  say "1) Доступ к новому VPS: IP, SSH порт, root пароль"
  say "2) Уже готовый VPS-отчёт Warren на роутере"
  say "3) Готовую proxy-ссылку (например vless://...), которую понимает Podkop"
  say ""
}

auto_select_existing_report() {
  report_list="$(vps_report_files)"
  report_count="$(printf "%s\n" "$report_list" | sed '/^$/d' | wc -l | tr -d ' ')"

  [ "${report_count:-0}" -gt 0 ] || fail "На роутере нет VPS-отчётов Warren. Выбери новый VPS или вставь ссылку конфигурации."

  say ""
  say "Доступные VPS-отчёты Warren:"
  report_index=1
  printf "%s\n" "$report_list" | while IFS= read -r report_file; do
    [ -n "$report_file" ] || continue
    say "$report_index) $(basename "$report_file" .txt)"
    report_index=$((report_index + 1))
  done
  ask "Выбор VPS-отчёта" AUTO_REPORT_CHOICE "1"

  case "$AUTO_REPORT_CHOICE" in
    ''|*[!0-9]*) fail "Введи номер VPS-отчёта" ;;
  esac

  [ "$AUTO_REPORT_CHOICE" -ge 1 ] && [ "$AUTO_REPORT_CHOICE" -le "$report_count" ] || fail "Нет VPS-отчёта с номером $AUTO_REPORT_CHOICE"
  SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n "${AUTO_REPORT_CHOICE}p")"
  [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось определить выбранный VPS-отчёт"

  VLESS="$(vps_report_vless_link "$SELECTED_VPS_REPORT")"
  [ -n "$VLESS" ] || fail "Не удалось прочитать proxy-ссылку из отчёта: $SELECTED_VPS_REPORT"
  proxy_link_supported "$VLESS" || fail "Ссылка из VPS-отчёта не поддерживается Podkop."

  AUTO_VPS_SOURCE="report"
  VPS_HOST=""
  VPS_SSH_PORT="22"
  VPS_ROOT_PASSWORD=""
}

auto_collect_proxy_source() {
  while :; do
    say ""
    say "Источник proxy-конфига для Podkop:"
    say "1) Настроить новый VPS через Warren"
    say "2) Использовать уже готовый VPS-отчёт Warren"
    say "3) У меня уже есть ссылка конфигурации"
    ask "Ввод (1-3)" AUTO_PROXY_SOURCE_CHOICE "${AUTO_PROXY_SOURCE_CHOICE:-1}"

    case "$AUTO_PROXY_SOURCE_CHOICE" in
      1)
        AUTO_VPS_SOURCE="new_vps"
        SELECTED_VPS_REPORT=""
        VLESS=""
        ask "IP адрес VPS" VPS_HOST "${VPS_HOST:-}"
        [ -n "$VPS_HOST" ] || fail "IP адрес VPS пустой"
        ask "SSH порт VPS" VPS_SSH_PORT "${VPS_SSH_PORT:-22}"
        [ -n "$VPS_SSH_PORT" ] || fail "SSH порт VPS пустой"
        ask "Root пароль VPS" VPS_ROOT_PASSWORD "${VPS_ROOT_PASSWORD:-}"
        [ -n "$VPS_ROOT_PASSWORD" ] || fail "Root пароль VPS пустой"
        return 0
        ;;
      2)
        auto_select_existing_report
        return 0
        ;;
      3)
        AUTO_VPS_SOURCE="link"
        SELECTED_VPS_REPORT=""
        VPS_HOST=""
        VPS_SSH_PORT="22"
        VPS_ROOT_PASSWORD=""
        ask "Вставь ссылку конфигурации для Podkop" VLESS "${VLESS:-}"
        [ -n "$VLESS" ] || fail "Ссылка конфигурации пустая"
        proxy_link_supported "$VLESS" || fail "Ссылка должна начинаться с vless://, ss://, trojan://, socks4://, socks5://, hy2:// или hysteria2://"
        return 0
        ;;
      *)
        fail "Введи 1, 2 или 3"
        ;;
    esac
  done
}

auto_collect_inputs() {
  auto_show_requirements
  ask "Если всё готово и все данные под рукой, начать сбор? (y/n)" AUTO_READY_CONFIRM "y"
  case "$AUTO_READY_CONFIRM" in
    y|Y) ;;
    n|N) fail "Полный авторежим отменён: сначала подготовь все данные." ;;
    *) fail "Введи y или n" ;;
  esac

  LIST_RU="1"
  LIST_CF="1"
  LIST_META="1"
  LIST_GOOGLE_AI="1"

  auto_collect_proxy_source

  say ""
  say "Сводка полного авторежима:"
  say "- UI Warren: будет установлен"
  case "${AUTO_VPS_SOURCE:-}" in
    new_vps)
      say "- VPS: будет настроен новый ${VPS_HOST}:${VPS_SSH_PORT}"
      ;;
    report)
      say "- VPS: будет использован отчёт $(basename "${SELECTED_VPS_REPORT:-}" .txt)"
      ;;
    link)
      say "- VPS: шаг установки VPS пропускается, будет использована готовая ссылка"
      ;;
  esac
  say "- Podkop: будет установлен и настроен"
  ask "Запомнить этот сценарий и стартовать авторежим? (y/n)" AUTO_PLAN_CONFIRM "y"
  case "$AUTO_PLAN_CONFIRM" in
    y|Y) ;;
    n|N) fail "Полный авторежим отменён пользователем." ;;
    *) fail "Введи y или n" ;;
  esac
}

menu() {
  clear_terminal
  print_banner
  PRE_MENU_MODE="${MODE:-}"
  PRE_MENU_STATE="$(get_state)"

  say ""
  say "Главное меню:"
  say "0) Полный авторежим"
  say "1) Базовые настройки"
  say "2) Добавить UI Warren в роутер"
  say "3) Настрой мне VPS"
  say "4) Podkop"
  say "5) Доустановить Amnezia в Podkop"
  say "6) QoS для Amnezia"
  say "7) Управление Amnezia клиентами"
  say "8) Remote Admin (WIP)"
  say "9) USB модем настрой (WIP)"
  say "10) Telegram-бот для Podkop"
  say "11) Диагностика Podkop/VPS"
  say "12) Проверка SNI-кандидатов Reality"
  say "13) NaiveProxy (WIP)"
  say "14) Shadowsocks fallback (WIP)"
  say "99) Установить всё из РФ сегмента (WIP)"
  ask "Ввод (0-14, 99)" MENU_CHOICE "0"

  case "$MENU_CHOICE" in
    0) MODE="auto" ;;
    1) MODE="basic" ;;
    2) MODE="initialize" ;;
    3) MODE="vps" ;;
    4) podkop_submenu ;;
    5) MODE="add_private" ;;
    6) MODE="qos_private" ;;
    7) MODE="manage_private" ;;
    8) MODE="remote_admin" ;;
    9) MODE="usb_modem" ;;
    10) MODE="tg_bot" ;;
    11) MODE="diagnostics" ;;
    12) MODE="sni_checker" ;;
    13) MODE="naiveproxy_wip" ;;
    14) MODE="shadowsocks_fallback_wip" ;;
    99) MODE="rf_bundle_wip" ;;
    *) fail "Неверный выбор: $MENU_CHOICE" ;;
  esac

  if [ "$MODE" = "basic" ]; then
    if [ "$PRE_MENU_MODE" != "basic" ] || [ "${PRE_MENU_STATE:-0}" -ge 75 ]; then
      set_state 0
    fi
  fi

  VLESS="${VLESS:-}"
  LIST_RU="${LIST_RU:-1}"
  LIST_CF="${LIST_CF:-1}"
  LIST_META="${LIST_META:-1}"
  LIST_GOOGLE_AI="${LIST_GOOGLE_AI:-1}"
  AWG_ENDPOINT="${AWG_ENDPOINT:-}"
  VPS_HOST="${VPS_HOST:-}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

  case "$MODE" in
    initialize|manage_private|vps|podkop_backup|qos_private|remote_admin|usb_modem|tg_bot|diagnostics|sni_checker|rf_bundle_wip|naiveproxy_wip|shadowsocks_fallback_wip)
      SELECTED_MODE="$MODE"
      load_conf_if_exists || true
      MODE="$SELECTED_MODE"
      conf_set MODE "$MODE"
      say "${GREEN}DONE${NC}  Режим сохранён в $CONF"
      return 0
      ;;
  esac

  VLESS=""
  LIST_RU="1"
  LIST_CF="1"
  LIST_META="1"
  LIST_GOOGLE_AI="1"

  if [ "$MODE" = "auto" ]; then
    AUTO_VPS_SOURCE="${AUTO_VPS_SOURCE:-}"
    auto_collect_inputs
  fi

  AWG_ENDPOINT=""

  if [ "$MODE" = "auto" ]; then
    capture_runtime_inputs
  fi
  save_conf
  done_ "Параметры сохранены в $CONF"
}
