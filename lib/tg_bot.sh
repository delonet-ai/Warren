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
  cat > "$TG_BOT_BIN" <<'BOT_EOF'
#!/bin/sh

CONFIG="${WARREN_TG_BOT_CONFIG:-/etc/warren/warren-tg-bot.conf}"
ENDPOINTS="${WARREN_TG_BOT_ENDPOINTS:-/etc/warren/warren-vless-endpoints}"
REPORTS_DIR="${WARREN_TG_BOT_REPORTS_DIR:-/etc/warren/vps/reports}"
WARREN_CONF="${WARREN_TG_BOT_WARREN_CONF:-/etc/warren/warren.conf}"
OFFSET_FILE="${WARREN_TG_BOT_OFFSET:-/tmp/warren-tg-bot.offset}"
PENDING_DIR="${WARREN_TG_BOT_PENDING_DIR:-/tmp/warren-tg-bot-pending}"
REPORT_CACHE="${WARREN_TG_BOT_REPORT_CACHE:-/tmp/warren-tg-bot-reports.tsv}"
AMZ_CACHE="${WARREN_TG_BOT_AMZ_CACHE:-/tmp/warren-tg-bot-amnezia.tsv}"
AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_CLIENT_DIR="${AWG_CLIENT_DIR:-/etc/amneziawg/clients}"
AWG_SERVER_DIR="${AWG_SERVER_DIR:-/etc/amneziawg}"
AWG_SERVER_NET_PREFIX="${AWG_SERVER_NET_PREFIX:-10.10.10}"
AWG_SERVER_IP="${AWG_SERVER_NET_PREFIX}.1"
AWG_LISTEN_PORT="${AWG_LISTEN_PORT:-51820}"

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
  if [ -r "$WARREN_CONF" ]; then
    # shellcheck disable=SC1090
    . "$WARREN_CONF"
  fi
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
    printf "REPORTS_DIR=%s\n" "$(shell_quote_value "${REPORTS_DIR:-/etc/warren/vps/reports}")"
    printf "WARREN_CONF=%s\n" "$(shell_quote_value "${WARREN_CONF:-/etc/warren/warren.conf}")"
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

send_document() {
  chat_id="$1"
  file="$2"
  caption="${3:-}"
  [ -r "$file" ] || return 1
  curl -fsS -X POST "${API}/sendDocument" \
    -F "chat_id=${chat_id}" \
    -F "document=@${file}" \
    -F "caption=${caption}" >/dev/null 2>&1 || return 1
}

send_photo() {
  chat_id="$1"
  file="$2"
  caption="${3:-}"
  [ -r "$file" ] || return 1
  curl -fsS -X POST "${API}/sendPhoto" \
    -F "chat_id=${chat_id}" \
    -F "photo=@${file}" \
    -F "caption=${caption}" >/dev/null 2>&1 || return 1
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
      [{text:"Amnezia клиенты",callback_data:"amz_menu"}],
      [{text:"Выбор Endpoint",callback_data:"endpoint_choose"}],
      [{text:"Редактор Endpoint",callback_data:"endpoint_editor"}],
      [{text:"Последний VPS",callback_data:"getvps"}],
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

amz_menu_keyboard() {
  jq -cn '{
    inline_keyboard: [
      [{text:"Список клиентов",callback_data:"amz_list"}],
      [{text:"Создать клиента",callback_data:"amz_create"}],
      [{text:"Показать QR",callback_data:"amz_pick_qr"},{text:"Показать конфиг",callback_data:"amz_pick_conf"}],
      [{text:"Удалить клиента",callback_data:"amz_pick_delete"}],
      [{text:"Назад",callback_data:"main"}]
    ]
  }'
}

restart_podkop() {
  uci commit podkop >/dev/null 2>&1 || return 1
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

amz_server_ready() {
  command -v awg >/dev/null 2>&1 || return 1
  [ -f "$AWG_SERVER_DIR/server.key" ] || return 1
  [ -f "$AWG_SERVER_DIR/server.pub" ] || return 1
  uci -q get network."$AWG_IFACE".proto 2>/dev/null | grep -qx 'amneziawg' || return 1
  [ -n "${AWG_ENDPOINT:-}" ] || return 1
  return 0
}

amz_interface_running() {
  command -v ip >/dev/null 2>&1 || return 0
  ip link show "$AWG_IFACE" >/dev/null 2>&1
}

amz_require_ready_text() {
  if ! amz_server_ready; then
    printf "AmneziaWG server ещё не готов. Сначала в SSH запусти пункт 5: Доустановить Amnezia в Podkop."
    return 1
  fi
  if ! amz_interface_running; then
    /etc/init.d/network restart >/dev/null 2>&1 || true
    sleep 2
    if ! amz_interface_running; then
      printf "AmneziaWG server настроен, но интерфейс %s не поднят. Проверь OpenWrt network/system log." "$AWG_IFACE"
      return 1
    fi
  fi
  return 0
}

amz_validate_client_name() {
  name="$1"
  [ -n "$name" ] || return 1
  printf "%s" "$name" | grep -Eq '^[A-Za-z0-9._-]{1,32}$'
}

amz_peer_sections() {
  uci show network 2>/dev/null | grep "=amneziawg_${AWG_IFACE}" | cut -d. -f2
}

amz_find_section_by_name() {
  name="$1"
  amz_peer_sections | while read -r sec; do
    desc="$(uci -q get network."$sec".description || uci -q get network."$sec".name || true)"
    [ "$desc" = "$name" ] && { echo "$sec"; break; }
  done
}

amz_client_exists() {
  name="$1"
  [ -f "$AWG_CLIENT_DIR/$name.conf" ] && return 0
  [ -n "$(amz_find_section_by_name "$name")" ] && return 0
  return 1
}

amz_next_free_ip32() {
  used="$(uci show network 2>/dev/null | sed -n "s/.*'\(${AWG_SERVER_NET_PREFIX}\.[0-9]\+\)\/32'.*/\1/p")"
  i=2
  while [ "$i" -le 254 ]; do
    ip="${AWG_SERVER_NET_PREFIX}.${i}"
    echo "$used" | grep -qx "$ip" || { echo "$ip/32"; return 0; }
    i=$((i + 1))
  done
  return 1
}

amz_obfuscation_defaults() {
  AWG_JC="${AWG_JC:-4}"
  AWG_JMIN="${AWG_JMIN:-40}"
  AWG_JMAX="${AWG_JMAX:-70}"
  AWG_S1="${AWG_S1:-0}"
  AWG_S2="${AWG_S2:-0}"
  AWG_H1="${AWG_H1:-1}"
  AWG_H2="${AWG_H2:-2}"
  AWG_H3="${AWG_H3:-3}"
  AWG_H4="${AWG_H4:-4}"
}

amz_create_config() {
  name="$1"
  client_priv="$2"
  client_ip32="$3"
  client_psk="$4"
  file="$AWG_CLIENT_DIR/$name.conf"
  amz_obfuscation_defaults
  cat > "$file" <<AMZ_CONF_EOF
[Interface]
PrivateKey = $client_priv
Address = ${client_ip32%/32}/32
DNS = $AWG_SERVER_IP
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $(cat "$AWG_SERVER_DIR/server.pub")
PresharedKey = $client_psk
Endpoint = $AWG_ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
AMZ_CONF_EOF
}

amz_create_client() {
  name="$1"
  amz_validate_client_name "$name" || return 3
  amz_client_exists "$name" && return 2
  mkdir -p "$AWG_CLIENT_DIR" || return 1
  client_ip32="$(amz_next_free_ip32)" || return 1
  umask 077
  client_priv="$(awg genkey)" || return 1
  client_pub="$(printf "%s" "$client_priv" | awg pubkey)" || return 1
  client_psk="$(awg genpsk)" || return 1
  sec="$(uci add network "amneziawg_${AWG_IFACE}")" || return 1
  uci set network."$sec".description="$name"
  uci set network."$sec".public_key="$client_pub"
  uci set network."$sec".preshared_key="$client_psk"
  uci set network."$sec".route_allowed_ips='0'
  uci set network."$sec".persistent_keepalive='25'
  uci add_list network."$sec".allowed_ips="$client_ip32"
  uci commit network || return 1
  /etc/init.d/network restart >/dev/null 2>&1 || true
  amz_create_config "$name" "$client_priv" "$client_ip32" "$client_psk" || return 1
  printf "%s" "$client_ip32"
  return 0
}

amz_refresh_cache() {
  : > "$AMZ_CACHE"
  i=1
  amz_peer_sections | while read -r sec; do
    [ -n "$sec" ] || continue
    name="$(uci -q get network."$sec".description || uci -q get network."$sec".name || true)"
    ip="$(uci -q get network."$sec".allowed_ips || true)"
    [ -n "$name" ] || name="$sec"
    printf "%s\t%s\t%s\t%s\n" "$i" "$name" "$ip" "$sec" >> "$AMZ_CACHE"
    i=$((i + 1))
  done
}

amz_client_count() {
  amz_refresh_cache
  [ -s "$AMZ_CACHE" ] || { echo 0; return 0; }
  wc -l < "$AMZ_CACHE" | tr -d ' '
}

amz_list_text() {
  amz_refresh_cache
  count="$(amz_client_count)"
  {
    printf "Amnezia клиенты: %s\n\n" "${count:-0}"
    if [ ! -s "$AMZ_CACHE" ]; then
      printf "Клиентов пока нет."
      return 0
    fi
    while IFS='	' read -r idx name ip sec; do
      printf "%s) %s  %s\n" "$idx" "$name" "${ip:-no-ip}"
    done < "$AMZ_CACHE"
  }
}

amz_pick_keyboard() {
  action="$1"
  amz_refresh_cache
  tmp="/tmp/warren-tg-amz-keyboard.$$"
  printf '{"inline_keyboard":[[{"text":"Назад","callback_data":"amz_menu"}]' > "$tmp"
  shown=0
  if [ -s "$AMZ_CACHE" ]; then
    while IFS='	' read -r idx name ip sec; do
      [ "$shown" -lt 19 ] || break
      label="${name} ${ip}"
      printf ',[{"text":%s,"callback_data":"amz_%s:%s"}]' "$(jq_string "$label")" "$action" "$idx" >> "$tmp"
      shown=$((shown + 1))
    done < "$AMZ_CACHE"
  fi
  printf ']}' >> "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

amz_name_by_index() {
  index="$1"
  amz_refresh_cache
  sed -n "${index}p" "$AMZ_CACHE" 2>/dev/null | cut -f2
}

amz_conf_file_by_index() {
  index="$1"
  name="$(amz_name_by_index "$index")"
  [ -n "$name" ] || return 1
  printf "%s/%s.conf" "$AWG_CLIENT_DIR" "$name"
}

amz_delete_by_index() {
  index="$1"
  amz_refresh_cache
  line="$(sed -n "${index}p" "$AMZ_CACHE" 2>/dev/null)"
  [ -n "$line" ] || return 1
  name="$(printf "%s" "$line" | cut -f2)"
  sec="$(printf "%s" "$line" | cut -f4)"
  [ -n "$sec" ] || return 1
  uci delete network."$sec" || return 1
  uci commit network || return 1
  /etc/init.d/network restart >/dev/null 2>&1 || true
  rm -f "$AWG_CLIENT_DIR/$name.conf" 2>/dev/null || true
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
  uci -q del podkop.main.urltest_proxy_links >/dev/null 2>&1 || true
  uci -q del podkop.main.selector_proxy_links >/dev/null 2>&1 || true
  restart_podkop || return 2
  return 0
}

use_auto_endpoint() {
  seed_endpoints
  [ -s "$ENDPOINTS" ] || return 1
  uci set podkop.main.proxy_config_type='urltest'
  uci -q del podkop.main.proxy_string >/dev/null 2>&1 || true
  uci -q del podkop.main.urltest_proxy_links >/dev/null 2>&1 || true
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

latest_vps_report() {
  [ -d "$REPORTS_DIR" ] || return 1
  ls -1t "$REPORTS_DIR"/*.txt 2>/dev/null | head -n1
}

vps_report_value() {
  report_file="$1"
  label="$2"
  [ -r "$report_file" ] || return 1
  sed -n "s/^${label}: //p" "$report_file" | head -n1
}

tg_vps_report_summary_text() {
  report_file="$1"
  [ -r "$report_file" ] || return 1
  host="$(vps_report_value "$report_file" "Host")"
  ssh_port="$(vps_report_value "$report_file" "SSH port")"
  root_password="$(vps_report_value "$report_file" "SSH root password")"
  panel_url="$(vps_report_value "$report_file" "3x-ui URL")"
  panel_user="$(vps_report_value "$report_file" "3x-ui username")"
  panel_pass="$(vps_report_value "$report_file" "3x-ui password")"
  vless_link="$(vps_report_value "$report_file" "VLESS inbound link")"
  report_path="$report_file"
  printf "Последний VPS\n\nHost: %s\nSSH: root@%s:%s\nRoot password: %s\n3x-ui URL: %s\n3x-ui login: %s\n3x-ui password: %s\nVLESS: %s\nReport: %s" \
    "${host:-unknown}" "${host:-unknown}" "${ssh_port:-22}" "${root_password:-unknown}" \
    "${panel_url:-unknown}" "${panel_user:-unknown}" "${panel_pass:-unknown}" \
    "${vless_link:-unknown}" "${report_path:-unknown}"
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
/clients
/amz_create phone
/getvps
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

show_amz_menu() {
  chat_id="$1"
  clear_pending "$chat_id"
  ready_error="$(amz_require_ready_text)" || {
    send_keyboard "$chat_id" "$ready_error" "$(main_keyboard)"
    return 0
  }
  send_keyboard "$chat_id" "Amnezia клиенты: выбери действие." "$(amz_menu_keyboard)"
}

show_amz_list() {
  chat_id="$1"
  ready_error="$(amz_require_ready_text)" || {
    send_keyboard "$chat_id" "$ready_error" "$(main_keyboard)"
    return 0
  }
  send_keyboard "$chat_id" "$(amz_list_text)" "$(amz_menu_keyboard)"
}

show_amz_picker() {
  chat_id="$1"
  action="$2"
  title="$3"
  ready_error="$(amz_require_ready_text)" || {
    send_keyboard "$chat_id" "$ready_error" "$(main_keyboard)"
    return 0
  }
  send_keyboard "$chat_id" "$title" "$(amz_pick_keyboard "$action")"
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
    amz_create)
      ready_error="$(amz_require_ready_text)" || {
        send_keyboard "$chat_id" "$ready_error" "$(main_keyboard)"
        return 0
      }
      created_ip="$(amz_create_client "$text")"
      rc="$?"
      if [ "$rc" -eq 3 ]; then
        send_keyboard "$chat_id" "Имя клиента: 1-32 символа, латиница, цифры, точка, подчёркивание или дефис." "$(amz_menu_keyboard)"
      elif [ "$rc" -eq 2 ]; then
        send_keyboard "$chat_id" "Клиент уже существует: ${text}" "$(amz_menu_keyboard)"
      elif [ "$rc" -eq 0 ]; then
        send_keyboard "$chat_id" "Клиент создан: ${text} ${created_ip}" "$(amz_menu_keyboard)"
        conf_file="$AWG_CLIENT_DIR/$text.conf"
        if command -v qrencode >/dev/null 2>&1; then
          qr_file="/tmp/warren-amz-${text}.png"
          qrencode -o "$qr_file" < "$conf_file" >/dev/null 2>&1 && send_photo "$chat_id" "$qr_file" "QR для ${text}" || true
          rm -f "$qr_file" 2>/dev/null || true
        fi
        send_document "$chat_id" "$conf_file" "Конфиг ${text}" || true
      else
        send_keyboard "$chat_id" "Не получилось создать клиента. Проверь AmneziaWG на роутере." "$(amz_menu_keyboard)"
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
    /amnezia|/clients)
      show_amz_menu "$chat_id"
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
    /amz_create)
      [ -n "$arg" ] || {
        set_pending "$chat_id" amz_create
        send_keyboard "$chat_id" "Пришли имя нового Amnezia-клиента." "$(amz_menu_keyboard)"
        return 0
      }
      set_pending "$chat_id" amz_create
      handle_pending_text "$chat_id" "$arg"
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
    /getvps)
      report_file="$(latest_vps_report)"
      if [ -r "$report_file" ]; then
        send_message "$chat_id" "$(tg_vps_report_summary_text "$report_file")"
        send_document "$chat_id" "$report_file" "Последний VPS-отчёт Warren" || true
      else
        send_keyboard "$chat_id" "Сохранённых VPS-отчётов пока нет." "$(main_keyboard)"
      fi
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
    amz_menu)
      show_amz_menu "$chat_id"
      ;;
    amz_list)
      show_amz_list "$chat_id"
      ;;
    amz_create)
      ready_error="$(amz_require_ready_text)" || {
        send_keyboard "$chat_id" "$ready_error" "$(main_keyboard)"
        return 0
      }
      set_pending "$chat_id" amz_create
      send_keyboard "$chat_id" "Пришли имя нового Amnezia-клиента." "$(amz_menu_keyboard)"
      ;;
    amz_pick_qr)
      show_amz_picker "$chat_id" qr "Выбери клиента для QR."
      ;;
    amz_pick_conf)
      show_amz_picker "$chat_id" conf "Выбери клиента для отправки конфига."
      ;;
    amz_pick_delete)
      show_amz_picker "$chat_id" delete "Выбери клиента для удаления."
      ;;
    amz_qr:*)
      idx="${data#amz_qr:}"
      conf_file="$(amz_conf_file_by_index "$idx")"
      name="$(amz_name_by_index "$idx")"
      if [ -r "$conf_file" ] && command -v qrencode >/dev/null 2>&1; then
        qr_file="/tmp/warren-amz-${name}.png"
        qrencode -o "$qr_file" < "$conf_file" >/dev/null 2>&1 && send_photo "$chat_id" "$qr_file" "QR для ${name}" || send_document "$chat_id" "$conf_file" "Конфиг ${name}" || true
        rm -f "$qr_file" 2>/dev/null || true
        send_keyboard "$chat_id" "Готово." "$(amz_menu_keyboard)"
      elif [ -r "$conf_file" ]; then
        send_document "$chat_id" "$conf_file" "Конфиг ${name}" || true
        send_keyboard "$chat_id" "qrencode не найден, отправил конфиг файлом." "$(amz_menu_keyboard)"
      else
        send_keyboard "$chat_id" "Конфиг клиента не найден." "$(amz_menu_keyboard)"
      fi
      ;;
    amz_conf:*)
      idx="${data#amz_conf:}"
      conf_file="$(amz_conf_file_by_index "$idx")"
      name="$(amz_name_by_index "$idx")"
      if send_document "$chat_id" "$conf_file" "Конфиг ${name}"; then
        send_keyboard "$chat_id" "Конфиг отправлен." "$(amz_menu_keyboard)"
      else
        send_keyboard "$chat_id" "Конфиг клиента не найден." "$(amz_menu_keyboard)"
      fi
      ;;
    amz_delete:*)
      idx="${data#amz_delete:}"
      if amz_delete_by_index "$idx"; then
        send_keyboard "$chat_id" "Клиент удалён." "$(amz_menu_keyboard)"
      else
        send_keyboard "$chat_id" "Не получилось удалить клиента." "$(amz_menu_keyboard)"
      fi
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
    getvps)
      report_file="$(latest_vps_report)"
      if [ -r "$report_file" ]; then
        send_message "$chat_id" "$(tg_vps_report_summary_text "$report_file")"
        send_document "$chat_id" "$report_file" "Последний VPS-отчёт Warren" || true
      else
        send_keyboard "$chat_id" "Сохранённых VPS-отчётов пока нет." "$(main_keyboard)"
      fi
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
