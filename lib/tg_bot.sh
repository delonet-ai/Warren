TG_BOT_CONFIG="/etc/warren-tg-bot.conf"
TG_BOT_BIN="/usr/bin/warren-tg-bot"
TG_BOT_INIT="/etc/init.d/warren-tg-bot"
TG_BOT_ENDPOINTS="/etc/warren-vless-endpoints"
TG_BOT_REPORTS_DIR="/etc/vps/reports"

tg_bot_install_prereqs() {
  missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"

  if [ -n "$missing" ]; then
    opkg update
    opkg install ca-bundle ca-certificates $missing || fail "Не удалось установить пакеты для TG-бота:$missing"
  fi
}

tg_bot_write_runner() {
  cat > "$TG_BOT_BIN" <<'BOT_EOF'
#!/bin/sh

CONFIG="${WARREN_TG_BOT_CONFIG:-/etc/warren-tg-bot.conf}"
ENDPOINTS="${WARREN_TG_BOT_ENDPOINTS:-/etc/warren-vless-endpoints}"
REPORTS_DIR="${WARREN_TG_BOT_REPORTS_DIR:-/etc/vps/reports}"
OFFSET_FILE="${WARREN_TG_BOT_OFFSET:-/tmp/warren-tg-bot.offset}"
PENDING_DIR="${WARREN_TG_BOT_PENDING_DIR:-/tmp/warren-tg-bot-pending}"
REPORT_CACHE="${WARREN_TG_BOT_REPORT_CACHE:-/tmp/warren-tg-bot-reports.tsv}"

log() {
  logger -t warren-tg-bot "$*"
}

load_config() {
  [ -r "$CONFIG" ] || {
    log "config not found: $CONFIG"
    sleep 30
    return 1
  }
  # shellcheck disable=SC1090
  . "$CONFIG"
  [ -n "${TG_TOKEN:-}" ] || {
    log "TG_TOKEN is empty"
    sleep 30
    return 1
  }
  API="https://api.telegram.org/bot${TG_TOKEN}"
  return 0
}

shell_quote_value() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

save_bound_chat() {
  chat_id="$1"
  tmp="${CONFIG}.tmp"
  {
    printf "TG_TOKEN=%s\n" "$(shell_quote_value "$TG_TOKEN")"
    printf "ALLOWED_CHAT_ID=%s\n" "$(shell_quote_value "$chat_id")"
    printf "REPORTS_DIR=%s\n" "$(shell_quote_value "${REPORTS_DIR:-/etc/vps/reports}")"
  } > "$tmp" && mv "$tmp" "$CONFIG"
  chmod 600 "$CONFIG" 2>/dev/null || true
  ALLOWED_CHAT_ID="$chat_id"
}

jq_string() {
  jq -cn --arg value "$1" '$value'
}

button_obj() {
  text="$1"
  data="$2"
  jq -cn --arg text "$text" --arg data "$data" '{text:$text,callback_data:$data}'
}

send_message() {
  chat_id="$1"
  text="$2"
  curl -fsS -X POST "${API}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

send_keyboard() {
  chat_id="$1"
  text="$2"
  markup="$3"
  curl -fsS -X POST "${API}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "reply_markup=${markup}" >/dev/null 2>&1 || true
}

answer_callback() {
  callback_id="$1"
  text="${2:-}"
  if [ -n "$text" ]; then
    curl -fsS -X POST "${API}/answerCallbackQuery" \
      -d "callback_query_id=${callback_id}" \
      --data-urlencode "text=${text}" >/dev/null 2>&1 || true
  else
    curl -fsS -X POST "${API}/answerCallbackQuery" \
      -d "callback_query_id=${callback_id}" >/dev/null 2>&1 || true
  fi
}

main_keyboard() {
  jq -cn '{
    inline_keyboard: [
      [{text:"Добавить в black",callback_data:"black_prompt"},{text:"Добавить в white",callback_data:"white_prompt"}],
      [{text:"IP без VPN",callback_data:"ip:no_vpn"},{text:"IP только с VPN",callback_data:"ip:vpn_only"}],
      [{text:"Выбор Endpoint",callback_data:"endpoint_choose"}],
      [{text:"Редактор Endpoint",callback_data:"endpoint_editor"}],
      [{text:"Статус",callback_data:"status"}]
    ]
  }'
}

ip_main_keyboard() {
  jq -cn '{
    inline_keyboard: [
      [{text:"IP без VPN",callback_data:"ip:no_vpn"},{text:"IP только с VPN",callback_data:"ip:vpn_only"}],
      [{text:"Главное меню",callback_data:"main"}]
    ]
  }'
}

back_keyboard() {
  jq -cn '{inline_keyboard:[[{text:"Назад",callback_data:"main"}]]}'
}

restart_podkop() {
  uci commit podkop >/dev/null 2>&1 || return 1
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

normalize_domain() {
  printf "%s" "$1" \
    | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s/:.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | tr 'A-Z' 'a-z'
}

valid_domain() {
  domain="$1"
  [ -n "$domain" ] || return 1
  [ ${#domain} -le 253 ] || return 1
  printf "%s" "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
}

valid_ip_or_cidr() {
  value="$1"
  printf "%s\n" "$value" | awk -F/ '
    NF == 1 || NF == 2 {
      octet_count = split($1, octets, ".");
      if (octet_count != 4) exit 1;
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/) exit 1;
        if (octets[i] < 0 || octets[i] > 255) exit 1;
      }
      if (NF == 2 && ($2 !~ /^[0-9]+$/ || $2 < 0 || $2 > 32)) exit 1;
      ok = 1;
    }
    END { exit ok ? 0 : 1 }
  '
}

uci_list_has() {
  section="$1"
  option="$2"
  value="$3"
  uci -q get "podkop.${section}.${option}" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$value"
}

add_domain_to_section() {
  section="$1"
  domain="$2"
  connection_type="$3"

  uci -q get "podkop.${section}" >/dev/null 2>&1 || uci set "podkop.${section}=section"
  uci set "podkop.${section}.connection_type=${connection_type}"
  uci set "podkop.${section}.user_domain_list_type=dynamic"
  if uci_list_has "$section" user_domains "$domain"; then
    return 2
  fi
  uci add_list "podkop.${section}.user_domains=${domain}"
  restart_podkop || return 1
  return 0
}

ip_list_meta() {
  list="$1"
  case "$list" in
    no_vpn)
      IP_SECTION="settings"
      IP_OPTION="routing_excluded_ips"
      IP_TITLE="IP без VPN"
      IP_DESCRIPTION="Эти IP будут добавлены в Routing Excluded IPs. Podkop исключит такие устройства из проксирования/VPN."
      IP_PENDING="ip_no_vpn"
      ;;
    vpn_only)
      IP_SECTION="main"
      IP_OPTION="fully_routed_ips"
      IP_TITLE="IP только с VPN"
      IP_DESCRIPTION="Эти IP будут добавлены в Fully Routed IPs. Весь трафик таких устройств пойдёт через выбранный endpoint/VPN секции."
      IP_PENDING="ip_vpn_only"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

ip_list_values() {
  list="$1"
  ip_list_meta "$list" || return 1
  uci -q get "podkop.${IP_SECTION}.${IP_OPTION}" 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
}

ip_list_count() {
  list="$1"
  ip_list_values "$list" | wc -l | tr -d ' '
}

add_ip_to_list() {
  list="$1"
  value="$2"
  ip_list_meta "$list" || return 1
  valid_ip_or_cidr "$value" || return 3

  uci -q get "podkop.${IP_SECTION}" >/dev/null 2>&1 || {
    if [ "$IP_SECTION" = "settings" ]; then
      uci set "podkop.${IP_SECTION}=settings"
    else
      uci set "podkop.${IP_SECTION}=section"
    fi
  }

  if uci_list_has "$IP_SECTION" "$IP_OPTION" "$value"; then
    return 2
  fi

  uci add_list "podkop.${IP_SECTION}.${IP_OPTION}=${value}"
  restart_podkop || return 1
  return 0
}

delete_ip_from_list() {
  list="$1"
  index="$2"
  ip_list_meta "$list" || return 1
  case "$index" in
    ''|*[!0-9]*) return 1 ;;
  esac
  value="$(ip_list_values "$list" | sed -n "${index}p")"
  [ -n "$value" ] || return 1
  uci del_list "podkop.${IP_SECTION}.${IP_OPTION}=${value}" >/dev/null 2>&1 || return 1
  restart_podkop || return 1
  return 0
}

format_ip_list() {
  list="$1"
  values="$(ip_list_values "$list")"
  if [ -z "$values" ]; then
    printf "пусто"
    return 0
  fi
  printf "%s" "$values" | awk '{ printf "%s%s", sep, $0; sep=", " }'
}

ip_list_keyboard() {
  list="$1"
  ip_list_meta "$list" || return 1
  tmp="/tmp/warren-tg-ip-keyboard.$$"
  printf '{"inline_keyboard":[[{"text":"Назад","callback_data":"ip_main"}],[{"text":"Добавить новый","callback_data":"ip_add:%s"}]' "$list" > "$tmp"
  i=1
  shown=0
  ip_list_values "$list" | while IFS= read -r ip_value; do
    [ -n "$ip_value" ] || continue
    [ "$shown" -lt 18 ] || break
    printf ',[{"text":%s,"callback_data":"ip_del:%s:%s"}]' "$(jq_string "$ip_value")" "$list" "$i" >> "$tmp"
    i=$((i + 1))
    shown=$((shown + 1))
  done
  printf ']}' >> "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

ip_list_text() {
  list="$1"
  ip_list_meta "$list" || return 1
  count="$(ip_list_count "$list")"
  {
    printf "%s\n\n" "$IP_TITLE"
    printf "%s\n\n" "$IP_DESCRIPTION"
    printf "Всего IP/подсетей в списке: %s\n" "${count:-0}"
    if [ "${count:-0}" -gt 18 ]; then
      printf "В Telegram показаны первые 18 кнопок удаления. Остальные останутся в списке.\n"
    fi
    printf "\nНажми IP, чтобы удалить его из списка, или нажми Добавить новый."
  }
}

endpoint_label() {
  endpoint="$1"
  label="$(printf "%s" "$endpoint" | sed -n 's#^[^:]*://[^@]*@\([^:/?#]*\).*#\1#p')"
  [ -z "$label" ] && label="$(printf "%s" "$endpoint" | sed -n 's#^[^:]*://\([^:/?#]*\).*#\1#p')"
  [ -z "$label" ] && label="$(printf "%s" "$endpoint" | cut -c1-32)"
  printf "%s" "$label"
}

seed_endpoints() {
  [ -s "$ENDPOINTS" ] && return 0
  {
    uci -q get podkop.main.proxy_string 2>/dev/null || true
    uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n' || true
    uci -q get podkop.main.selector_proxy_links 2>/dev/null | tr ' ' '\n' || true
  } | sed '/^$/d' | awk '!seen[$0]++' > "$ENDPOINTS"
  chmod 600 "$ENDPOINTS" 2>/dev/null || true
}

list_endpoints() {
  seed_endpoints
  if [ ! -s "$ENDPOINTS" ]; then
    printf "Endpoints пока не найдены.\n"
    return 0
  fi
  awk '{ printf "%d) %s\n", NR, $0 }' "$ENDPOINTS"
}

endpoint_count() {
  seed_endpoints
  [ -s "$ENDPOINTS" ] || {
    echo 0
    return 0
  }
  wc -l < "$ENDPOINTS" | tr -d ' '
}

add_endpoint() {
  endpoint="$1"
  printf "%s" "$endpoint" | grep -Eq '^(vless|ss|trojan|socks4|socks5|hy2|hysteria2)://' || return 1
  seed_endpoints
  if grep -Fxq -- "$endpoint" "$ENDPOINTS" 2>/dev/null; then
    return 2
  fi
  printf "%s\n" "$endpoint" >> "$ENDPOINTS"
  chmod 600 "$ENDPOINTS" 2>/dev/null || true
  return 0
}

delete_endpoint() {
  index="$1"
  case "$index" in
    ''|*[!0-9]*) return 1 ;;
  esac
  seed_endpoints
  [ -s "$ENDPOINTS" ] || return 1
  tmp="${ENDPOINTS}.tmp"
  awk -v n="$index" 'NR != n { print }' "$ENDPOINTS" > "$tmp" || return 1
  mv "$tmp" "$ENDPOINTS"
  chmod 600 "$ENDPOINTS" 2>/dev/null || true
  return 0
}

use_endpoint() {
  index="$1"
  case "$index" in
    ''|*[!0-9]*) return 1 ;;
  esac
  seed_endpoints
  endpoint="$(sed -n "${index}p" "$ENDPOINTS" 2>/dev/null)"
  [ -n "$endpoint" ] || return 1
  uci set podkop.main.proxy_config_type='url'
  uci set "podkop.main.proxy_string=${endpoint}"
  uci -q del podkop.main.urltest_proxy_links
  uci -q del podkop.main.selector_proxy_links
  restart_podkop || return 2
  return 0
}

use_auto_endpoint() {
  seed_endpoints
  [ -s "$ENDPOINTS" ] || return 1
  uci set podkop.main.proxy_config_type='urltest'
  uci -q del podkop.main.proxy_string
  uci -q del podkop.main.urltest_proxy_links
  while IFS= read -r endpoint; do
    [ -n "$endpoint" ] || continue
    uci add_list "podkop.main.urltest_proxy_links=${endpoint}"
  done < "$ENDPOINTS"
  uci set podkop.main.urltest_check_interval='3m'
  uci set podkop.main.urltest_tolerance='50'
  uci set podkop.main.urltest_testing_url='https://www.gstatic.com/generate_204'
  restart_podkop || return 2
  return 0
}

endpoint_choose_keyboard() {
  seed_endpoints
  tmp="/tmp/warren-tg-endpoint-keyboard.$$"
  printf '{"inline_keyboard":[[{"text":"Auto","callback_data":"use_auto"}]' > "$tmp"
  i=1
  if [ -s "$ENDPOINTS" ]; then
    while IFS= read -r endpoint; do
      [ -n "$endpoint" ] || continue
      label="$(endpoint_label "$endpoint")"
      printf ',[{"text":%s,"callback_data":"use:%s"}]' "$(jq_string "$label")" "$i" >> "$tmp"
      i=$((i + 1))
    done < "$ENDPOINTS"
  fi
  printf ',[{"text":"Назад","callback_data":"main"}]]}' >> "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

endpoint_editor_keyboard() {
  jq -cn '{
    inline_keyboard: [
      [{text:"Добавить Endpoint",callback_data:"endpoint_add"}],
      [{text:"Удалить Endpoint",callback_data:"endpoint_delete"}],
      [{text:"Назад",callback_data:"main"}]
    ]
  }'
}

endpoint_delete_keyboard() {
  seed_endpoints
  tmp="/tmp/warren-tg-delete-keyboard.$$"
  printf '{"inline_keyboard":[' > "$tmp"
  first=1
  i=1
  if [ -s "$ENDPOINTS" ]; then
    while IFS= read -r endpoint; do
      [ -n "$endpoint" ] || continue
      label="$(endpoint_label "$endpoint")"
      [ "$first" -eq 1 ] || printf ',' >> "$tmp"
      printf '[{"text":%s,"callback_data":"delete:%s"}]' "$(jq_string "$label")" "$i" >> "$tmp"
      first=0
      i=$((i + 1))
    done < "$ENDPOINTS"
  fi
  [ "$first" -eq 1 ] || printf ',' >> "$tmp"
  printf '[{"text":"Назад","callback_data":"endpoint_editor"}]]}' >> "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

refresh_report_cache() {
  : > "$REPORT_CACHE"
  [ -d "$REPORTS_DIR" ] || return 0
  find "$REPORTS_DIR" -maxdepth 1 -type f -name '*.txt' | sort | while IFS= read -r report_file; do
    link="$(sed -n 's/^VLESS inbound link: //p' "$report_file" | head -n1)"
    [ -n "$link" ] || continue
    host="$(sed -n 's/^Host: //p' "$report_file" | head -n1)"
    [ -z "$host" ] && host="$(basename "$report_file" .txt)"
    printf "%s\t%s\n" "$host" "$link" >> "$REPORT_CACHE"
  done
}

endpoint_add_keyboard() {
  refresh_report_cache
  tmp="/tmp/warren-tg-add-keyboard.$$"
  printf '{"inline_keyboard":[' > "$tmp"
  first=1
  i=1
  if [ -s "$REPORT_CACHE" ]; then
    while IFS='	' read -r host link; do
      [ -n "$link" ] || continue
      [ "$first" -eq 1 ] || printf ',' >> "$tmp"
      printf '[{"text":%s,"callback_data":"add_report:%s"}]' "$(jq_string "$host")" "$i" >> "$tmp"
      first=0
      i=$((i + 1))
    done < "$REPORT_CACHE"
  fi
  [ "$first" -eq 1 ] || printf ',' >> "$tmp"
  printf '[{"text":"Ввести свой","callback_data":"endpoint_manual"}],[{"text":"Назад","callback_data":"endpoint_editor"}]]}' >> "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

add_report_endpoint() {
  index="$1"
  case "$index" in
    ''|*[!0-9]*) return 1 ;;
  esac
  refresh_report_cache
  line="$(sed -n "${index}p" "$REPORT_CACHE" 2>/dev/null)"
  [ -n "$line" ] || return 1
  link="$(printf "%s" "$line" | cut -f2-)"
  add_endpoint "$link"
}

status_text() {
  active_type="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || echo unknown)"
  active_proxy="$(uci -q get podkop.main.proxy_string 2>/dev/null || true)"
  black_count="$(uci -q get podkop.main.user_domains 2>/dev/null | wc -w | tr -d ' ')"
  white_count="$(uci -q get podkop.warren_whitelist.user_domains 2>/dev/null | wc -w | tr -d ' ')"
  endpoints="$(endpoint_count)"
  no_vpn_ips="$(format_ip_list no_vpn)"
  vpn_only_ips="$(format_ip_list vpn_only)"
  printf "Podkop: %s\nBlack/proxy domains: %s\nWhite/exclusion domains: %s\nEndpoints: %s\nActive endpoint: %s\n\nIP без VPN:\n%s\n\nIP только с VPN:\n%s\n" \
    "$active_type" "${black_count:-0}" "${white_count:-0}" "${endpoints:-0}" "${active_proxy:-not set}" "$no_vpn_ips" "$vpn_only_ips"
}

help_text() {
  cat <<'HELP_EOF'
Warren TG bot

Нажимай кнопки под сообщением. Текстом можно присылать домены или endpoint, когда бот попросит ввод.

Команды тоже работают:
/menu - открыть меню
/black example.com
/white example.com
/endpoints
/use 1
/add_endpoint vless://...
/no_vpn 192.168.1.20
/vpn_only 192.168.1.30
/status
HELP_EOF
}

pending_file() {
  chat_id="$1"
  mkdir -p "$PENDING_DIR" 2>/dev/null || true
  printf "%s/%s" "$PENDING_DIR" "$chat_id"
}

set_pending() {
  chat_id="$1"
  action="$2"
  printf "%s\n" "$action" > "$(pending_file "$chat_id")"
}

get_pending() {
  chat_id="$1"
  cat "$(pending_file "$chat_id")" 2>/dev/null || true
}

clear_pending() {
  chat_id="$1"
  rm -f "$(pending_file "$chat_id")" 2>/dev/null || true
}

show_main_menu() {
  chat_id="$1"
  clear_pending "$chat_id"
  send_keyboard "$chat_id" "Warren TG bot: выбери действие." "$(main_keyboard)"
}

show_endpoint_choose() {
  chat_id="$1"
  send_keyboard "$chat_id" "Выбор Endpoint. Auto включает URLTest по всем сохранённым endpoints." "$(endpoint_choose_keyboard)"
}

show_endpoint_editor() {
  chat_id="$1"
  send_keyboard "$chat_id" "Редактор Endpoint." "$(endpoint_editor_keyboard)"
}

show_ip_main() {
  chat_id="$1"
  clear_pending "$chat_id"
  send_keyboard "$chat_id" "IP routing: выбери список для управления." "$(ip_main_keyboard)"
}

show_ip_list() {
  chat_id="$1"
  list="$2"
  send_keyboard "$chat_id" "$(ip_list_text "$list")" "$(ip_list_keyboard "$list")"
}

handle_pending_text() {
  chat_id="$1"
  text="$2"
  pending="$(get_pending "$chat_id")"
  [ -n "$pending" ] || return 1

  clear_pending "$chat_id"
  case "$pending" in
    black)
      domain="$(normalize_domain "$text")"
      if ! valid_domain "$domain"; then
        send_keyboard "$chat_id" "Домен не похож на домен: ${text}" "$(back_keyboard)"
        return 0
      fi
      add_domain_to_section main "$domain" proxy
      rc="$?"
      if [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Уже есть в black/proxy list: ${domain}" "$(main_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Добавил в black/proxy list: ${domain}" "$(main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось добавить домен. Проверь Podkop на роутере." "$(main_keyboard)"
      fi
      ;;
    white)
      domain="$(normalize_domain "$text")"
      if ! valid_domain "$domain"; then
        send_keyboard "$chat_id" "Домен не похож на домен: ${text}" "$(back_keyboard)"
        return 0
      fi
      add_domain_to_section warren_whitelist "$domain" exclusion
      rc="$?"
      if [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Уже есть в white/exclusion list: ${domain}" "$(main_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Добавил в white/exclusion list: ${domain}" "$(main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось добавить домен. Проверь Podkop на роутере." "$(main_keyboard)"
      fi
      ;;
    endpoint_manual)
      add_endpoint "$text"
      rc="$?"
      if [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Endpoint уже есть." "$(endpoint_editor_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Endpoint добавлен." "$(endpoint_editor_keyboard)"
      else
        send_keyboard "$chat_id" "Endpoint должен начинаться с vless://, ss://, trojan://, socks4://, socks5://, hy2:// или hysteria2://." "$(endpoint_editor_keyboard)"
      fi
      ;;
    ip_no_vpn)
      add_ip_to_list no_vpn "$text"
      rc="$?"
      if [ "$rc" -eq 3 ]; then
        send_keyboard "$chat_id" "IP должен быть в формате 192.168.1.20 или 192.168.1.0/24." "$(ip_main_keyboard)"
      elif [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Этот IP уже есть в списке IP без VPN: ${text}" "$(ip_main_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Добавил в IP без VPN: ${text}" "$(ip_main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось добавить IP без VPN. Проверь Podkop на роутере." "$(ip_main_keyboard)"
      fi
      ;;
    ip_vpn_only)
      add_ip_to_list vpn_only "$text"
      rc="$?"
      if [ "$rc" -eq 3 ]; then
        send_keyboard "$chat_id" "IP должен быть в формате 192.168.1.20 или 192.168.1.0/24." "$(ip_main_keyboard)"
      elif [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Этот IP уже есть в списке IP только с VPN: ${text}" "$(ip_main_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Добавил в IP только с VPN: ${text}" "$(ip_main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось добавить IP только с VPN. Проверь Podkop на роутере." "$(ip_main_keyboard)"
      fi
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

handle_command() {
  chat_id="$1"
  text="$2"

  handle_pending_text "$chat_id" "$text" && return 0

  cmd="$(printf "%s" "$text" | awk '{print $1}')"
  arg="$(printf "%s" "$text" | sed 's/^[^[:space:]]*[[:space:]]*//')"
  [ "$arg" = "$cmd" ] && arg=""

  case "$cmd" in
    /start|/help)
      send_message "$chat_id" "$(help_text)"
      show_main_menu "$chat_id"
      ;;
    /menu)
      show_main_menu "$chat_id"
      ;;
    /black|/blacklist)
      [ -n "$arg" ] || {
        set_pending "$chat_id" black
        send_keyboard "$chat_id" "Пришли домен для black/proxy list." "$(back_keyboard)"
        return 0
      }
      set_pending "$chat_id" black
      handle_pending_text "$chat_id" "$arg"
      ;;
    /white|/whitelist)
      [ -n "$arg" ] || {
        set_pending "$chat_id" white
        send_keyboard "$chat_id" "Пришли домен для white/exclusion list." "$(back_keyboard)"
        return 0
      }
      set_pending "$chat_id" white
      handle_pending_text "$chat_id" "$arg"
      ;;
    /endpoints|/vless)
      send_keyboard "$chat_id" "$(list_endpoints)" "$(endpoint_choose_keyboard)"
      ;;
    /add_endpoint)
      [ -n "$arg" ] || {
        send_keyboard "$chat_id" "Выбери новый endpoint из отчётов VPS или введи свой." "$(endpoint_add_keyboard)"
        return 0
      }
      add_endpoint "$arg"
      rc="$?"
      if [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Endpoint уже есть." "$(endpoint_editor_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Endpoint добавлен." "$(endpoint_editor_keyboard)"
      else
        send_keyboard "$chat_id" "Endpoint должен начинаться с vless://, ss://, trojan://, socks4://, socks5://, hy2:// или hysteria2://." "$(endpoint_editor_keyboard)"
      fi
      ;;
    /no_vpn)
      [ -n "$arg" ] || {
        set_pending "$chat_id" ip_no_vpn
        send_keyboard "$chat_id" "Пришли IP или подсеть для списка IP без VPN." "$(ip_main_keyboard)"
        return 0
      }
      set_pending "$chat_id" ip_no_vpn
      handle_pending_text "$chat_id" "$arg"
      ;;
    /vpn_only)
      [ -n "$arg" ] || {
        set_pending "$chat_id" ip_vpn_only
        send_keyboard "$chat_id" "Пришли IP или подсеть для списка IP только с VPN." "$(ip_main_keyboard)"
        return 0
      }
      set_pending "$chat_id" ip_vpn_only
      handle_pending_text "$chat_id" "$arg"
      ;;
    /use)
      use_endpoint "$arg"
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Podkop переключен на endpoint #${arg}." "$(main_keyboard)"
      else
        send_keyboard "$chat_id" "Не нашёл endpoint #${arg}." "$(endpoint_choose_keyboard)"
      fi
      ;;
    /status)
      send_keyboard "$chat_id" "$(status_text)" "$(main_keyboard)"
      ;;
    *)
      send_keyboard "$chat_id" "Не понял команду. Нажми кнопку или напиши /help." "$(main_keyboard)"
      ;;
  esac
}

handle_callback() {
  chat_id="$1"
  callback_id="$2"
  data="$3"

  answer_callback "$callback_id"

  case "$data" in
    main)
      show_main_menu "$chat_id"
      ;;
    black_prompt)
      set_pending "$chat_id" black
      send_keyboard "$chat_id" "Пришли домен для black/proxy list." "$(back_keyboard)"
      ;;
    white_prompt)
      set_pending "$chat_id" white
      send_keyboard "$chat_id" "Пришли домен для white/exclusion list." "$(back_keyboard)"
      ;;
    ip_main)
      show_ip_main "$chat_id"
      ;;
    ip:no_vpn)
      show_ip_list "$chat_id" no_vpn
      ;;
    ip:vpn_only)
      show_ip_list "$chat_id" vpn_only
      ;;
    ip_add:no_vpn)
      set_pending "$chat_id" ip_no_vpn
      send_keyboard "$chat_id" "Пришли IP или подсеть для списка IP без VPN." "$(ip_main_keyboard)"
      ;;
    ip_add:vpn_only)
      set_pending "$chat_id" ip_vpn_only
      send_keyboard "$chat_id" "Пришли IP или подсеть для списка IP только с VPN." "$(ip_main_keyboard)"
      ;;
    ip_del:no_vpn:*)
      idx="${data#ip_del:no_vpn:}"
      delete_ip_from_list no_vpn "$idx"
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Удалил IP из списка IP без VPN." "$(ip_main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось удалить IP из списка IP без VPN." "$(ip_main_keyboard)"
      fi
      ;;
    ip_del:vpn_only:*)
      idx="${data#ip_del:vpn_only:}"
      delete_ip_from_list vpn_only "$idx"
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Удалил IP из списка IP только с VPN." "$(ip_main_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось удалить IP из списка IP только с VPN." "$(ip_main_keyboard)"
      fi
      ;;
    endpoint_choose)
      show_endpoint_choose "$chat_id"
      ;;
    endpoint_editor)
      show_endpoint_editor "$chat_id"
      ;;
    endpoint_add)
      send_keyboard "$chat_id" "Выбери endpoint из новых VPS-отчётов или введи свой." "$(endpoint_add_keyboard)"
      ;;
    endpoint_manual)
      set_pending "$chat_id" endpoint_manual
      send_keyboard "$chat_id" "Пришли endpoint одной строкой." "$(back_keyboard)"
      ;;
    endpoint_delete)
      send_keyboard "$chat_id" "Выбери endpoint для удаления." "$(endpoint_delete_keyboard)"
      ;;
    use_auto)
      use_auto_endpoint
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Включил Auto: Podkop URLTest по всем сохранённым endpoints." "$(main_keyboard)"
      else
        send_keyboard "$chat_id" "Не нашёл endpoints для Auto." "$(endpoint_editor_keyboard)"
      fi
      ;;
    use:*)
      idx="${data#use:}"
      use_endpoint "$idx"
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Podkop переключен на endpoint #${idx}." "$(main_keyboard)"
      else
        send_keyboard "$chat_id" "Не нашёл endpoint #${idx}." "$(endpoint_choose_keyboard)"
      fi
      ;;
    delete:*)
      idx="${data#delete:}"
      delete_endpoint "$idx"
      rc="$?"
      if [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Endpoint #${idx} удалён." "$(endpoint_editor_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось удалить endpoint #${idx}." "$(endpoint_editor_keyboard)"
      fi
      ;;
    add_report:*)
      idx="${data#add_report:}"
      add_report_endpoint "$idx"
      rc="$?"
      if [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Endpoint из VPS-отчёта уже есть." "$(endpoint_editor_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Endpoint из VPS-отчёта добавлен." "$(endpoint_editor_keyboard)"
      else
        send_keyboard "$chat_id" "Не смог прочитать endpoint из VPS-отчёта." "$(endpoint_add_keyboard)"
      fi
      ;;
    status)
      send_keyboard "$chat_id" "$(status_text)" "$(main_keyboard)"
      ;;
    *)
      send_keyboard "$chat_id" "Неизвестная кнопка. Вернул главное меню." "$(main_keyboard)"
      ;;
  esac
}

process_updates() {
  offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  updates="$(curl -fsS "${API}/getUpdates?timeout=25&offset=${offset}" 2>/dev/null)" || {
    sleep 5
    return 0
  }

  printf "%s" "$updates" | jq -r '
    .result[] |
    if .callback_query then
      [.update_id, "callback", (.callback_query.message.chat.id // empty), (.callback_query.id // ""), (.callback_query.data // "")] | @tsv
    else
      [.update_id, "message", (.message.chat.id // .edited_message.chat.id // empty), "", (.message.text // .edited_message.text // "")] | @tsv
    end
  ' 2>/dev/null |
    while IFS='	' read -r update_id kind chat_id callback_id payload; do
      [ -n "$update_id" ] || continue
      next_offset=$((update_id + 1))
      printf "%s\n" "$next_offset" > "$OFFSET_FILE"

      [ -n "$chat_id" ] || continue
      if [ -z "${ALLOWED_CHAT_ID:-}" ]; then
        save_bound_chat "$chat_id"
        send_message "$chat_id" "Этот чат привязан к Warren TG bot."
        show_main_menu "$chat_id"
      fi
      [ "$chat_id" = "${ALLOWED_CHAT_ID:-}" ] || continue

      case "$kind" in
        callback)
          handle_callback "$chat_id" "$callback_id" "$payload"
          ;;
        message)
          [ -n "$payload" ] || continue
          handle_command "$chat_id" "$payload"
          ;;
      esac
    done
}

while :; do
  load_config || continue
  seed_endpoints
  process_updates
done
BOT_EOF
  chmod 755 "$TG_BOT_BIN" || fail "Не удалось сделать $TG_BOT_BIN исполняемым"
}

tg_bot_write_init() {
  cat > "$TG_BOT_INIT" <<'INIT_EOF'
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/warren-tg-bot
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
INIT_EOF
  chmod 755 "$TG_BOT_INIT" || fail "Не удалось сделать $TG_BOT_INIT исполняемым"
}

tg_bot_seed_endpoints() {
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
  ask "TG bot token от BotFather" TG_BOT_TOKEN ""
  [ -n "$TG_BOT_TOKEN" ] || fail "TG token пустой"

  say ""
  say "Можно заранее указать chat_id, чтобы бот отвечал только тебе."
  say "Если оставить пустым, первый чат, который напишет /start, будет привязан автоматически."
  ask "Allowed Telegram chat_id (можно пусто)" TG_BOT_CHAT_ID ""

  tg_bot_install_prereqs
  tg_bot_write_runner
  tg_bot_write_init

  {
    printf "TG_TOKEN=%s\n" "$(quote_sh "$TG_BOT_TOKEN")"
    printf "ALLOWED_CHAT_ID=%s\n" "$(quote_sh "$TG_BOT_CHAT_ID")"
    printf "REPORTS_DIR=%s\n" "$(quote_sh "$TG_BOT_REPORTS_DIR")"
  } > "$TG_BOT_CONFIG"
  chmod 600 "$TG_BOT_CONFIG" 2>/dev/null || true

  tg_bot_seed_endpoints

  "$TG_BOT_INIT" enable >/dev/null 2>&1 || true
  "$TG_BOT_INIT" restart >/dev/null 2>&1 || fail "Не удалось запустить warren-tg-bot"

  done_ "Telegram-бот установлен и запущен"
  say "Напиши боту /start. Дальше можно работать кнопками."
}
