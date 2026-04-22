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
  say ""
}

progress_stage() {
  st="$1"
  if [ "$st" -lt 10 ]; then
    echo 0
  elif [ "$st" -lt 20 ]; then
    echo 1
  elif [ "$st" -lt 30 ]; then
    echo 2
  elif [ "$st" -lt 40 ]; then
    echo 3
  elif [ "$st" -lt 75 ]; then
    echo 4
  elif [ "$st" -lt 80 ]; then
    echo 5
  elif [ "$st" -lt 90 ]; then
    echo 6
  elif [ "$st" -lt 110 ]; then
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

  say ""
  say "┌──────────────────────── Прогресс ────────────────────────────┐"
  _stage_line 0 "$cur" "Preflight (версия / интернет / время)"
  _stage_line 1 "$cur" "Установка пакетов (полный список)"
  _stage_line 2 "$cur" "Проверка/выбор expand-root"
  _stage_line 3 "$cur" "Expand-root (resize → reboot)"
  _stage_line 4 "$cur" "Пакеты после resize + проверка места"
  _stage_line 5 "$cur" "Установка Podkop"
  _stage_line 6 "$cur" "Настройка Podkop (VLESS + community_lists)"
  _stage_line 7 "$cur" "Private access (сервер)"
  _stage_line 8 "$cur" "Private clients + QR"
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

menu() {
  clear_terminal
  print_banner

  say ""
  say "Главное меню:"
  say "0) Initialize (НАЖМИ МЕНЯ ПЕРВЫМ) — установить Warren UI в LuCI"
  say "1) Автоматический режим"
  say "2) Basic setup"
  say "3) Настрой мне VPS"
  say "4) Podkop"
  say "5) Доустановить Amnezia в Podkop"
  say "6) QoS для Amnezia"
  say "7) Управление Amnezia клиентами"
  say "8) Remote Admin (WIP)"
  say "9) USB модем настрой (WIP)"
  say "10) Telegram-бот для Podkop"
  say "11) Диагностика Podkop/VPS"
  ask "Ввод (0-11)" MENU_CHOICE "0"

  case "$MENU_CHOICE" in
    0) MODE="initialize" ;;
    1) MODE="auto" ;;
    2) MODE="basic" ;;
    3) MODE="vps" ;;
    4) podkop_submenu ;;
    5) MODE="add_private" ;;
    6) MODE="qos_private" ;;
    7) MODE="manage_private" ;;
    8) MODE="remote_admin" ;;
    9) MODE="usb_modem" ;;
    10) MODE="tg_bot" ;;
    11) MODE="diagnostics" ;;
    *) fail "Неверный выбор: $MENU_CHOICE" ;;
  esac

  VLESS="${VLESS:-}"
  LIST_RU="${LIST_RU:-1}"
  LIST_CF="${LIST_CF:-1}"
  LIST_META="${LIST_META:-1}"
  LIST_GOOGLE_AI="${LIST_GOOGLE_AI:-1}"
  AWG_ENDPOINT="${AWG_ENDPOINT:-}"
  VPS_HOST="${VPS_HOST:-}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

  case "$MODE" in
    initialize|manage_private|vps|podkop_backup|qos_private|remote_admin|usb_modem|tg_bot|diagnostics)
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
    say ""
    say "Списки (community_lists) — 0/1:"
    ask "russia_inside" LIST_RU "1"
    ask "cloudflare" LIST_CF "1"
    ask "meta" LIST_META "1"
    ask "google_ai" LIST_GOOGLE_AI "1"
  fi

  AWG_ENDPOINT=""
  VPS_HOST="${VPS_HOST:-}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

  [ "$MODE" = "auto" ] && capture_runtime_inputs
  save_conf
  done_ "Параметры сохранены в $CONF"
}
