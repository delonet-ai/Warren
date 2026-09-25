TG_BOT_CONFIG="${WARREN_BASE_DIR:-/etc/warren}/warren-tg-bot.conf"
TG_BOT_BIN="/usr/bin/warren-tg-bot"
TG_BOT_INIT="/etc/init.d/warren-tg-bot"
TG_BOT_ENDPOINTS="${WARREN_BASE_DIR:-/etc/warren}/warren-vless-endpoints"
TG_BOT_REPORTS_DIR="${WARREN_BASE_DIR:-/etc/warren}/vps/reports"

tg_bot_install_prereqs() {
  missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"

  if [ -n "$missing" ]; then
    # shellcheck disable=SC2086
    pkg_ensure_installed ca-bundle ca-certificates $missing
  fi
}

tg_bot_write_runner() {
  warren_install_payload warren-tg-bot "$TG_BOT_BIN"
  chmod 755 "$TG_BOT_BIN" || fail "Не удалось сделать $TG_BOT_BIN исполняемым"
}

tg_bot_write_init() {
  warren_install_payload warren-tg-bot.init "$TG_BOT_INIT"
  chmod 755 "$TG_BOT_INIT" || fail "Не удалось сделать $TG_BOT_INIT исполняемым"
}

tg_bot_seed_endpoints() {
  mkdir -p "$(dirname "$TG_BOT_ENDPOINTS")" || fail "Не удалось создать каталог для endpoints TG-бота"
  {
    uci -q get podkop.main.proxy_string 2>/dev/null || true
    uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n' || true
    uci -q get podkop.main.selector_proxy_links 2>/dev/null | tr ' ' '\n' || true
  } | sed '/^$/d' | awk '!seen[$0]++' > "$TG_BOT_ENDPOINTS"
  chmod 600 "$TG_BOT_ENDPOINTS" 2>/dev/null || true
}

run_tg_bot_flow() {
  podkop_require_existing_config

  say ""
  say "Telegram-бот будет работать прямо на OpenWrt как сервис warren-tg-bot."
  ask "TG bot token от BotFather" TG_BOT_TOKEN "${TG_BOT_TOKEN:-}"
  [ -n "$TG_BOT_TOKEN" ] || fail "TG token пустой"

  say ""
  say "Можно заранее указать chat_id, чтобы бот отвечал только тебе."
  say "Если оставить пустым, первый чат, который напишет /start, будет привязан автоматически."
  ask "Allowed Telegram chat_id (можно пусто)" TG_BOT_CHAT_ID "${TG_BOT_CHAT_ID:-}"

  tg_bot_install_prereqs
  tg_bot_write_runner
  tg_bot_write_init
  mkdir -p "$(dirname "$TG_BOT_CONFIG")" || fail "Не удалось создать каталог конфигурации TG-бота"

  {
    printf "TG_TOKEN=%s\n" "$(quote_sh "$TG_BOT_TOKEN")"
    printf "ALLOWED_CHAT_ID=%s\n" "$(quote_sh "$TG_BOT_CHAT_ID")"
    printf "REPORTS_DIR=%s\n" "$(quote_sh "$TG_BOT_REPORTS_DIR")"
    printf "WARREN_CONF=%s\n" "$(quote_sh "$CONF")"
  } > "$TG_BOT_CONFIG"
  chmod 600 "$TG_BOT_CONFIG" 2>/dev/null || true

  tg_bot_seed_endpoints

  "$TG_BOT_INIT" enable >/dev/null 2>&1 || true
  "$TG_BOT_INIT" restart >/dev/null 2>&1 || fail "Не удалось запустить warren-tg-bot"

  say "${GREEN}DONE${NC}  Telegram-бот установлен и запущен"
  say "Напиши боту /start. Дальше можно работать кнопками."
}
