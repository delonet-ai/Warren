#!/bin/sh
# Warren bootstrap: packages -> expand-root (reboot) -> podkop -> wireguard -> peers+QR
# Designed for OpenWrt 24.10.x on NanoPi R5S/R5C
# Usage (GitHub): wget -qO- "https://raw.githubusercontent.com/delonet-ai/Warren/main/bootstrap.sh" | sh

set -e

STATE="/etc/warren.state"
CONF="/etc/warren.conf"
LOG="/root/warren.log"
TTY="/dev/tty"
EXPAND_ROOT_URL="${EXPAND_ROOT_URL:-https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0}"
PODKOP_INSTALL_URL="${PODKOP_INSTALL_URL:-https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh}"
EXPAND_ROOT_SHA256="${EXPAND_ROOT_SHA256:-}"
PODKOP_INSTALL_SHA256="${PODKOP_INSTALL_SHA256:-}"

GREEN="\033[1;32m"; RED="\033[1;31m"; YELLOW="\033[1;33m"; NC="\033[0m"

say()   { printf "%b\n" "$*"; }
done_() {
  say "${GREEN}DONE${NC}  $*"
  print_progress
  sleep 5
}
info()  { say "${YELLOW}INFO${NC}  $*"; }
warn()  { say "${YELLOW}WARN${NC}  $*"; sleep 5; }
fail()  { say "${RED}FAIL${NC}  $*"; exit 1; }
log()   { echo "[$(date +'%F %T')] $*" >> "$LOG"; }

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

# Определяем, какой большой шаг считается "текущим" по state.
# Возвращает индекс этапа 0..N
progress_stage() {
  st="$1"
  if   [ "$st" -lt 10  ]; then echo 0
  elif [ "$st" -lt 20  ]; then echo 1
  elif [ "$st" -lt 30  ]; then echo 2
  elif [ "$st" -lt 40  ]; then echo 3
  elif [ "$st" -lt 75  ]; then echo 4
  elif [ "$st" -lt 80  ]; then echo 5
  elif [ "$st" -lt 90  ]; then echo 6
  elif [ "$st" -lt 110 ]; then echo 7
  else echo 8
  fi
}

# Красивый вывод статуса этапа
_stage_line() {
  idx="$1"; cur="$2"; title="$3"
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




get_state(){ [ -f "$STATE" ] && cat "$STATE" || echo "0"; }
set_state(){ echo "$1" > "$STATE"; sync; }

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

save_conf() {
  {
    printf "MODE=%s\n" "$(quote_sh "${MODE:-}")"
    printf "VLESS=%s\n" "$(quote_sh "${VLESS:-}")"
    printf "LIST_RU=%s\n" "$(quote_sh "${LIST_RU:-}")"
    printf "LIST_CF=%s\n" "$(quote_sh "${LIST_CF:-}")"
    printf "LIST_META=%s\n" "$(quote_sh "${LIST_META:-}")"
    printf "LIST_GOOGLE_AI=%s\n" "$(quote_sh "${LIST_GOOGLE_AI:-}")"
    printf "WG_ENDPOINT=%s\n" "$(quote_sh "${WG_ENDPOINT:-}")"
  } > "$CONF"
}

conf_set() {
  key="$1"
  val="$2"

  case "$key" in
    MODE|VLESS|LIST_RU|LIST_CF|LIST_META|LIST_GOOGLE_AI|WG_ENDPOINT) ;;
    *) fail "Неизвестный ключ конфига: $key" ;;
  esac

  eval "$key=$(quote_sh "$val")"
  save_conf
}

download_file() {
  url="$1"
  out="$2"
  expected_sha="$3"
  label="$4"

  wget -qO "$out" "$url" || fail "Не удалось скачать $label: $url"

  if [ -n "$expected_sha" ]; then
    actual_sha="$(sha256sum "$out" | awk '{print $1}')"
    [ "$actual_sha" = "$expected_sha" ] || fail "SHA256 mismatch для $label: ожидался $expected_sha, получен $actual_sha"
  else
    warn "$label скачан без SHA256-проверки. Для жёсткой верификации задай ${label}_SHA256."
  fi
}

# Read from /dev/tty so menu works even when script is piped: wget -O- ... | sh
ask() {
  # ask "Prompt" VAR "default"
  prompt="$1"; var="$2"; def="${3:-}"
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

uciq(){ uci -q "$@"; }

# -------------------- MENU --------------------
menu() {
  say ""
  say "Выбери конфигурацию:"
  say "0) Basic setup (пакеты + expand-root)"
  say "1) Podkop"
  say "2) Podkop + WireGuard Private"
 say "3) Доустановить WireGuard Private к Podkop"
say "4) Управление WireGuard клиентами (создание/удаление/QR/конфиги)"
ask "Ввод (0/1/2/3/4)" MODE "2"
case "$MODE" in 0|1|2|3|4) ;; *) fail "Неверный выбор MODE=$MODE" ;; esac

# Если выбрали управление WG — сразу открываем подменю и выходим
if [ "$MODE" = "4" ]; then
  load_conf 2>/dev/null || true
  wg_manage_menu
  exit 0
fi

  VLESS=""
  LIST_RU="1"; LIST_CF="1"; LIST_META="1"; LIST_GOOGLE_AI="1"

  if [ "$MODE" = "1" ] || [ "$MODE" = "2" ]; then
    ask "Вставь строку VLESS (одной строкой)" VLESS ""
    say ""
    say "Списки (community_lists) — 0/1:"
    ask "russia_inside" LIST_RU "1"
    ask "cloudflare"   LIST_CF "1"
    ask "meta"         LIST_META "1"
    ask "google_ai"    LIST_GOOGLE_AI "1"
  fi

  # WireGuard endpoint for peer configs (optional, asked later if empty)
  WG_ENDPOINT=""

  save_conf
  done_ "Параметры сохранены в $CONF"
}

load_conf() {
  [ -f "$CONF" ] || menu
  # shellcheck disable=SC1090
  . "$CONF"
}

# -------------------- PREFLIGHT --------------------
check_openwrt() {
  rel="$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE" 2>/dev/null || true)"
  echo "$rel" | grep -q "^24\.10" || fail "Нужен OpenWrt 24.10.x (сейчас: ${rel:-unknown})."
  done_ "OpenWrt версия: $rel"
}

check_inet() {
  ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || fail "Нет интернета (ping 1.1.1.1)."
  # DNS+TLS: important for opkg + https downloads
  wget -q --spider https://downloads.openwrt.org/ || fail "Нет DNS/TLS (wget https://downloads.openwrt.org)."
  done_ "Интернет + HTTPS OK"
}

sync_time() {
  ntpd -q -p 0.openwrt.pool.ntp.org >/dev/null 2>&1 || warn "NTP не сработал (продолжаю)."
  done_ "Время проверено"
}

# -------------------- PACKAGES (YOUR FULL LIST) --------------------
install_full_pkg_list() {
  opkg update
  # Your list + wget-ssl (needed for https fetching reliably)
  opkg install \
    parted losetup resize2fs blkid e2fsprogs block-mount fstrim tune2fs \
    ca-bundle ca-certificates wget-ssl curl nano-full tcpdump kmod-nft-tproxy ss
  done_ "Установлен полный список пакетов"
}

overlay_report_and_ask_expand() {
  # Показываем размер overlay (это то, что реально важно для пакетов)
  # total_kb used_kb avail_kb
  set -- $(df -k /overlay 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
  total_kb="${1:-0}"; used_kb="${2:-0}"; avail_kb="${3:-0}"

  total_mb=$((total_kb/1024))
  used_mb=$((used_kb/1024))
  avail_mb=$((avail_kb/1024))

  say ""
  say "Overlay (место под пакеты): всего ${total_mb}MB, занято ${used_mb}MB, свободно ${avail_mb}MB"
  say ""

  # Дефолт: если overlay уже >= 1024MB, то обычно expand-root не нужен
  def="y"
  [ "$total_mb" -ge 1024 ] && def="n"

  ask "Делать expand-root? (y/n)" DO_EXPAND "$def"
  case "$DO_EXPAND" in
    y|Y) return 0 ;;
    n|N) return 1 ;;
    *) fail "Введи y или n" ;;
  esac
}


check_space_overlay() {
  free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$free_kb" ] || fail "Не вижу /overlay"
  done_ "Свободно /overlay: $((free_kb/1024)) MB"
}

# -------------------- EXPAND ROOT --------------------
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
  # This script typically triggers a reboot itself; we reboot anyway after marking progress.
  sh /etc/uci-defaults/70-rootpt-resize || true
  set_state 60
  done_ "Запущен expand-root. Сейчас будет ребут. После загрузки запусти скрипт снова."
  reboot
  fail "Команда reboot не выполнилась"
}

# -------------------- PODKOP --------------------
install_podkop() {
  download_file "$PODKOP_INSTALL_URL" /tmp/podkop-install.sh "$PODKOP_INSTALL_SHA256" "PODKOP_INSTALL"
  chmod +x /tmp/podkop-install.sh

  # ВАЖНО: заставляем install.sh читать ввод с терминала
  if [ -r /dev/tty ]; then
    sh /tmp/podkop-install.sh </dev/tty >/dev/tty 2>&1
  else
    fail "Нет /dev/tty. Запусти через интерактивный SSH или: ssh -t root@ip 'sh /tmp/bootstrap.sh'"
  fi

  done_ "Podkop установлен/обновлён"
}
configure_podkop_full() {
  # Если VLESS пустой — спросим заново и сохраним в конфиг, чтобы не падать
  if [ -z "${VLESS:-}" ]; then
    warn "VLESS пустой — сейчас спрошу заново."
    ask "Вставь строку VLESS (одной строкой)" VLESS ""
    conf_set VLESS "$VLESS"
  fi
  [ -n "${VLESS:-}" ] || fail "VLESS пустой. Запусти скрипт заново и введи VLESS (MODE 1/2)."

  # settings section
  uciq get podkop.settings >/dev/null || uciq set podkop.settings='settings'
  uciq set podkop.settings.dns_type='doh'
  uciq set podkop.settings.dns_server='1.1.1.1'
  uciq set podkop.settings.bootstrap_dns_server='77.88.8.8'
  uciq set podkop.settings.dns_rewrite_ttl='60'
  uciq set podkop.settings.enable_output_network_interface='0'
  uciq set podkop.settings.enable_badwan_interface_monitoring='0'
  uciq set podkop.settings.enable_yacd='0'
  uciq set podkop.settings.disable_quic='0'
  uciq set podkop.settings.update_interval='1d'
  uciq set podkop.settings.download_lists_via_proxy='0'
  uciq set podkop.settings.dont_touch_dhcp='0'
  uciq set podkop.settings.config_path='/etc/sing-box/config.json'
  uciq set podkop.settings.cache_path='/tmp/sing-box/cache.db'
  uciq set podkop.settings.exclude_ntp='0'
  uciq set podkop.settings.shutdown_correctly='0'

  # source_network_interfaces: br-lan always; wg0 if WG enabled
   uciq -q del podkop.settings.source_network_interfaces
  uciq add_list podkop.settings.source_network_interfaces='br-lan'
  if [ "$MODE" = "2" ] || [ "$MODE" = "3" ]; then
    uciq add_list podkop.settings.source_network_interfaces='wg0'
  fi

  # main section
  uciq get podkop.main >/dev/null || uciq set podkop.main='section'
  uciq set podkop.main.connection_type='proxy'
  uciq set podkop.main.proxy_config_type='url'
  uciq set podkop.main.enable_udp_over_tcp='0'
  uciq set podkop.main.proxy_string="$VLESS"
  uciq set podkop.main.user_domain_list_type='dynamic'
  uciq set podkop.main.user_subnet_list_type='disabled'
  uciq set podkop.main.mixed_proxy_enabled='0'

  # community_lists from menu
  uciq -q del podkop.main.community_lists
  [ "${LIST_RU:-0}" = "1" ]       && uciq add_list podkop.main.community_lists='russia_inside'
  [ "${LIST_CF:-0}" = "1" ]       && uciq add_list podkop.main.community_lists='cloudflare'
  [ "${LIST_META:-0}" = "1" ]     && uciq add_list podkop.main.community_lists='meta'
  [ "${LIST_GOOGLE_AI:-0}" = "1" ]&& uciq add_list podkop.main.community_lists='google_ai'

  uciq commit podkop
  /etc/init.d/podkop restart >/dev/null 2>&1 || true
  done_ "Podkop настроен и перезапущен"
}

patch_podkop_add_wg0_only() {
  # MODE=3: only add wg0 to source interfaces (do not touch VLESS/lists)
  uciq get podkop.settings >/dev/null || uciq set podkop.settings='settings'
  if ! uci -q get podkop.settings.source_network_interfaces 2>/dev/null | grep -q 'wg0'; then
    uciq add_list podkop.settings.source_network_interfaces='wg0'
    uciq commit podkop
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
  fi
  done_ "Podkop: wg0 добавлен в source_network_interfaces"
}

# -------------------- WIREGUARD --------------------
install_wireguard() {
  opkg update
  opkg install kmod-wireguard wireguard-tools luci-app-wireguard qrencode
  done_ "WireGuard + QR установлены"
}

configure_wireguard_server() {
  mkdir -p /etc/wireguard
  if [ ! -f /etc/wireguard/server.key ]; then
    umask 077
    wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
  fi

  # wg0 как на эталоне: 10.10.10.1/24, порт 51820, defaultroute=0
  uciq set network.wg0='interface'
  uciq set network.wg0.proto='wireguard'
  uciq set network.wg0.private_key="$(cat /etc/wireguard/server.key)"
  uciq set network.wg0.listen_port='51820'
  uciq set network.wg0.defaultroute='0'
  uciq -q del network.wg0.addresses
  uciq add_list network.wg0.addresses='10.10.10.1/24'
  uciq commit network

  # Убираем (если вдруг остались) нашу старую зону wg и forwarding wg->wan
  uci -q delete firewall.wg >/dev/null 2>&1 || true
  uci -q delete firewall.wg_wan >/dev/null 2>&1 || true
  uci -q delete firewall.wg_in >/dev/null 2>&1 || true

  # Добавляем wg0 в зону LAN (как на эталоне)
  # (на чистом OpenWrt зона обычно называется firewall.@zone[0] с name='lan',
  #  но аккуратнее найти по имени)
  lan_zone="$(uci show firewall | grep "=zone" | cut -d. -f2 | while read -r z; do
    name="$(uci -q get firewall."$z".name || true)"
    [ "$name" = "lan" ] && echo "$z" && break
  done)"

  [ -n "$lan_zone" ] || fail "Не нашёл firewall zone 'lan'"

  # Добавим wg0 в список networks зоны lan (если ещё нет)
  if ! uci -q get firewall."$lan_zone".network 2>/dev/null | grep -qw 'wg0'; then
    uciq add_list firewall."$lan_zone".network='wg0'
  fi

  # Правило входа WireGuard с WAN: UDP/51820 (как на эталоне)
  uciq set firewall.wg_allow='rule'
  uciq set firewall.wg_allow.name='Allow-WireGuard-Inbound'
  uciq set firewall.wg_allow.src='wan'
  uciq set firewall.wg_allow.proto='udp'
  uciq set firewall.wg_allow.dest_port='51820'
  uciq set firewall.wg_allow.target='ACCEPT'

  # (опционально) гарантируем наличие forwarding lan->wan
  # на чистом OpenWrt оно обычно есть, но добавим, если отсутствует
  has_fwd="$(uci show firewall | grep "=forwarding" | grep -q "src='lan'.*dest='wan'" && echo 1 || echo 0)"
  if [ "$has_fwd" = "0" ]; then
    f="$(uci add firewall forwarding)"
    uciq set firewall."$f".src='lan'
    uciq set firewall."$f".dest='wan'
  fi

  uciq commit firewall
  /etc/init.d/network restart >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true

  done_ "WireGuard сервер wg0 настроен как на эталоне (wg0 в зоне lan)"
}

create_peer() {
  # create_peer "peer1" "10.7.0.2/32"
  name="$1"; ip="$2"
  dir="/etc/wireguard/clients"
  mkdir -p "$dir"

  umask 077
  priv="$(wg genkey)"
  pub="$(printf "%s" "$priv" | wg pubkey)"
  psk="$(wg genpsk)"

  sec="$(uci add network wireguard_wg0)"
  uciq set "network.$sec.public_key=$pub"
  uciq set "network.$sec.preshared_key=$psk"
  uciq add_list "network.$sec.allowed_ips=$ip"
  uciq set "network.$sec.description=$name"
  uciq commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true

  # Endpoint asked once (stored in CONF) unless already present
  if [ -z "${WG_ENDPOINT:-}" ]; then
    ask "Endpoint для клиентов (например: my.domain.com:51820)" WG_ENDPOINT ""
    # persist back to CONF
    conf_set WG_ENDPOINT "$WG_ENDPOINT"
  fi

  cat > "$dir/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = ${ip%/32}/32
DNS = 10.10.10.1

[Peer]
PublicKey = $(cat /etc/wireguard/server.pub)
PresharedKey = $psk
Endpoint = $WG_ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  say ""
  say "${GREEN}QR (ANSI) для $name:${NC}"
  qrencode -t ansiutf8 < "$dir/$name.conf" || true
  done_ "Peer $name создан: $dir/$name.conf"
}

WG_NET_PREFIX="10.10.10"
WG_SERVER_IP="${WG_NET_PREFIX}.1"
WG_CLIENT_DIR="/etc/wireguard/clients"

wg_clients_list() {
  say ""
  say "=== WireGuard клиенты (wg0) ==="
  # Вывод: section | description | allowed_ips
  uci show network 2>/dev/null | grep "=wireguard_wg0" | cut -d. -f2 | while read -r sec; do
    desc="$(uci -q get network."$sec".description || true)"
    ips="$(uci -q get network."$sec".allowed_ips || true)"
    [ -z "$desc" ] && desc="(no description)"
    say " - ${GREEN}${desc}${NC}  [$sec]  allowed_ips: ${ips:-none}"
  done
  say ""
}

wg_find_section_by_name() {
  # prints section id by description match (exact)
  name="$1"
  uci show network 2>/dev/null | grep "=wireguard_wg0" | cut -d. -f2 | while read -r sec; do
    desc="$(uci -q get network."$sec".description || true)"
    [ "$desc" = "$name" ] && { echo "$sec"; break; }
  done
}

wg_show_conf_text() {
  name="$1"
  file="$WG_CLIENT_DIR/$name.conf"
  [ -f "$file" ] || fail "Файл конфига не найден: $file"
  say ""
  say "=== $file ==="
  cat "$file"
  say ""
}

wg_show_conf_qr() {
  name="$1"
  file="$WG_CLIENT_DIR/$name.conf"
  [ -f "$file" ] || fail "Файл конфига не найден: $file"
  say ""
  say "${GREEN}QR (ANSI) для $name:${NC}"
  qrencode -t ansiutf8 < "$file" || fail "qrencode не сработал (проверь пакет qrencode)"
  say ""
}

wg_next_free_ip32() {
  # Find next free 10.10.10.X/32 starting from .2
  used="$(uci show network 2>/dev/null | grep "\.allowed_ips=" | sed -n "s/.*'\(${WG_NET_PREFIX}\.[0-9]\+\)\/32'.*/\1/p")"
  i=2
  while [ "$i" -le 254 ]; do
    ip="${WG_NET_PREFIX}.${i}"
    echo "$used" | grep -qx "$ip" || { echo "$ip/32"; return 0; }
    i=$((i+1))
  done
  return 1
}

wg_create_client() {
  mkdir -p "$WG_CLIENT_DIR"
  [ -f /etc/wireguard/server.pub ] || fail "Не найден /etc/wireguard/server.pub (сервер WG не настроен?)"

  ask "Имя нового клиента (латиница, без пробелов)" name ""
  [ -n "$name" ] || fail "Имя пустое"
  [ -f "$WG_CLIENT_DIR/$name.conf" ] && fail "Уже есть файл: $WG_CLIENT_DIR/$name.conf"

  # если endpoint не задан — спросим и сохраним
  if [ -z "${WG_ENDPOINT:-}" ]; then
    ask "Endpoint для клиентов (например: 89.207.218.164:51820)" WG_ENDPOINT ""
    conf_set WG_ENDPOINT "$WG_ENDPOINT"
  fi

  ip32="$(wg_next_free_ip32)" || fail "Не нашёл свободный IP в ${WG_NET_PREFIX}.0/24"
  umask 077
  priv="$(wg genkey)"
  pub="$(printf "%s" "$priv" | wg pubkey)"
  psk="$(wg genpsk)"

  sec="$(uci add network wireguard_wg0)"
  uciq set "network.$sec.description=$name"
  uciq set "network.$sec.public_key=$pub"
  uciq set "network.$sec.preshared_key=$psk"
  uciq add_list "network.$sec.allowed_ips=$ip32"
  uciq set "network.$sec.persistent_keepalive=25"
  uciq commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true

  cat > "$WG_CLIENT_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = ${ip32%/32}/32
DNS = $WG_SERVER_IP

[Peer]
PublicKey = $(cat /etc/wireguard/server.pub)
PresharedKey = $psk
Endpoint = $WG_ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  done_ "Клиент создан: $name ($ip32)"
  wg_show_conf_qr "$name"
}

wg_delete_client() {
  ask "Имя клиента для удаления" name ""
  [ -n "$name" ] || fail "Имя пустое"

  sec="$(wg_find_section_by_name "$name")"
  [ -n "$sec" ] || fail "Не нашёл клиента '$name' в UCI (network.$sec)"

  uciq delete network."$sec"
  uciq commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true

  rm -f "$WG_CLIENT_DIR/$name.conf" 2>/dev/null || true
  done_ "Клиент удалён: $name"
}

wg_manage_menu() {
  while true; do
    say ""
    say "=== Управление WireGuard (wg0) ==="
    say "1) Показать список клиентов"
    say "2) Показать QR для клиента"
    say "3) Показать текстовый конфиг клиента"
    say "4) Создать нового клиента"
    say "5) Удалить клиента"
    say "0) Назад"
    ask "Выбор" act "1"

    case "$act" in
      1) wg_clients_list ;;
      2) ask "Имя клиента" n ""; wg_show_conf_qr "$n" ;;
      3) ask "Имя клиента" n ""; wg_show_conf_text "$n" ;;
      4) wg_create_client ;;
      5) wg_delete_client ;;
      0) break ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}


# -------------------- MAIN --------------------
main() {
  [ -f "$CONF" ] || menu
  load_conf

 st="$(get_state)"
log "state=$st mode=$MODE"

print_banner
print_progress

  # --- preflight
  [ "$st" -lt 10 ] && check_openwrt && set_state 10
  [ "$st" -lt 20 ] && check_inet   && set_state 20
  [ "$st" -lt 30 ] && sync_time    && set_state 30

  # --- install FULL package list first (as requested)
  if [ "$st" -lt 40 ]; then
    if install_full_pkg_list; then
      set_state 40
    else
      warn "Установка пакетов упала (часто из-за места). Всё равно попробую expand-root, затем повторю установку."
      set_state 35
    fi
  fi

  [ "$st" -lt 45 ] && check_space_overlay && set_state 45

  # --- expand-root AFTER packages (as requested) — will reboot
   # Решаем, нужен ли expand-root
  if [ "$st" -lt 50 ]; then
    if overlay_report_and_ask_expand; then
      expand_root_prep
      set_state 50
    else
      done_ "Пропускаю expand-root по выбору пользователя"
      # перепрыгиваем шаги expand-root + пост-установка пакетов
      set_state 75
    fi
  fi

  # Если expand-root всё же выбран — запускаем и уходим в reboot
  [ "$st" -lt 60 ] && expand_root_run_and_reboot

  # После ребута (или если expand-root был нужен) — повторим установку пакетов и покажем место
  [ "$st" -lt 70 ] && install_full_pkg_list && set_state 70
  [ "$st" -lt 75 ] && check_space_overlay   && set_state 75


  # --- Podkop
  if [ "$MODE" = "1" ] || [ "$MODE" = "2" ]; then
    [ "$st" -lt 80 ] && install_podkop        && set_state 80
    [ "$st" -lt 90 ] && configure_podkop_full && set_state 90
  fi

  # --- WireGuard
  if [ "$MODE" = "2" ] || [ "$MODE" = "3" ]; then
    [ "$st" -lt 100 ] && install_wireguard          && set_state 100
    [ "$st" -lt 110 ] && configure_wireguard_server && set_state 110
    [ "$MODE" = "3" ] && [ "$st" -lt 115 ] && patch_podkop_add_wg0_only && set_state 115

    # peers/QR
    if [ "$st" -lt 120 ]; then
      ask "Сколько клиентов WireGuard создать сейчас?" PEERS "1"
      i=1
      while [ "$i" -le "$PEERS" ]; do
        name="peer$i"
        ip="10.10.10.$((i+1))/32"
        create_peer "$name" "$ip"
        i=$((i+1))
      done
      set_state 120
    fi
  fi

  done_ "Готово. State=$(get_state). Логи: $LOG"
  say "Если был ребут — просто запусти тот же скрипт снова, он продолжит."
}

main
