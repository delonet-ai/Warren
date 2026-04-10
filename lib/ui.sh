clear_terminal() {
  if [ -r "$TTY" ]; then
    printf '\033[2J\033[H' > "$TTY"
  else
    printf '\033[2J\033[H'
  fi
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
  _stage_line 7 "$cur" "WireGuard (установка + сервер)"
  _stage_line 8 "$cur" "Peers + QR (клиенты)"
  say "└──────────────────────────────────────────────────────────────┘"
  say "State: $st"
  say ""
}

ask() {
  prompt="$1"
  var="$2"
  def="${3:-}"

  if [ -r "$TTY" ]; then
    [ -n "$def" ] && printf "%s [%s]: " "$prompt" "$def" > "$TTY" || printf "%s: " "$prompt" > "$TTY"
    IFS= read -r ans < "$TTY" || ans=""
  else
    [ -n "$def" ] && printf "%s [%s]: " "$prompt" "$def" || printf "%s: " "$prompt"
    IFS= read -r ans || ans=""
  fi

  [ -z "$ans" ] && ans="$def"
  eval "$var=$(quote_sh "$ans")"
}

menu() {
  clear_terminal
  print_banner

  say ""
  say "Главное меню:"
  say "1) Автоматический режим"
  say "2) Basic setup"
  say "3) Настрой мне VPS"
  say "4) Podkop"
  say "5) Podkop + Amnezia Private"
  say "6) Доустановить Amnezia в Podkop"
  say "7) QoS для Amnezia"
  say "8) Управление Amnezia клиентами"
  say "9) Remote Admin (WIP)"
  say "10) USB модем настрой (WIP)"
  ask "Ввод (1-10)" MENU_CHOICE "4"

  case "$MENU_CHOICE" in
    1) MODE="auto" ;;
    2) MODE="basic" ;;
    3) MODE="vps" ;;
    4) MODE="podkop" ;;
    5) MODE="podkop_private" ;;
    6) MODE="add_private" ;;
    7) MODE="qos_private" ;;
    8) MODE="manage_private" ;;
    9) MODE="remote_admin" ;;
    10) MODE="usb_modem" ;;
    *) fail "Неверный выбор: $MENU_CHOICE" ;;
  esac

  VLESS="${VLESS:-}"
  LIST_RU="${LIST_RU:-1}"
  LIST_CF="${LIST_CF:-1}"
  LIST_META="${LIST_META:-1}"
  LIST_GOOGLE_AI="${LIST_GOOGLE_AI:-1}"
  WG_ENDPOINT="${WG_ENDPOINT:-}"
  VPS_HOST="${VPS_HOST:-}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

  case "$MODE" in
    manage_private|vps|qos_private|remote_admin|usb_modem)
      load_conf_if_exists || true
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

  if [ "$MODE" = "podkop" ] || [ "$MODE" = "podkop_private" ] || [ "$MODE" = "auto" ]; then
    ask "Вставь строку VLESS (одной строкой)" VLESS ""
    say ""
    say "Списки (community_lists) — 0/1:"
    ask "russia_inside" LIST_RU "1"
    ask "cloudflare" LIST_CF "1"
    ask "meta" LIST_META "1"
    ask "google_ai" LIST_GOOGLE_AI "1"
  fi

  WG_ENDPOINT=""
  VPS_HOST="${VPS_HOST:-}"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"

  [ "$MODE" = "auto" ] && capture_runtime_inputs
  save_conf
  done_ "Параметры сохранены в $CONF"
}
