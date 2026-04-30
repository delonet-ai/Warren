AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_CLIENT_DIR="${AWG_CLIENT_DIR:-/etc/amneziawg/clients}"
AWG_SERVER_DIR="${AWG_SERVER_DIR:-/etc/amneziawg}"
AWG_SERVER_NET_PREFIX="${AWG_SERVER_NET_PREFIX:-10.10.10}"
AWG_SERVER_IP="${AWG_SERVER_NET_PREFIX}.1"
AWG_STAGE_DIR="${AWG_STAGE_DIR:-/tmp/amneziawg}"
AWG_LISTEN_PORT="${AWG_LISTEN_PORT:-51820}"

AWG_PACKAGE_SOURCE_DEFAULT="${AWG_PACKAGE_SOURCE_DEFAULT:-slava-shchipunov}"
AWG_REPO_BASE_SLAVA="${AWG_REPO_BASE_SLAVA:-https://github.com/Slava-Shchipunov/awg-openwrt/releases/download}"

AWG_JC_DEFAULT="${AWG_JC_DEFAULT:-4}"
AWG_JMIN_DEFAULT="${AWG_JMIN_DEFAULT:-40}"
AWG_JMAX_DEFAULT="${AWG_JMAX_DEFAULT:-70}"
AWG_S1_DEFAULT="${AWG_S1_DEFAULT:-0}"
AWG_S2_DEFAULT="${AWG_S2_DEFAULT:-0}"
AWG_H1_DEFAULT="${AWG_H1_DEFAULT:-1}"
AWG_H2_DEFAULT="${AWG_H2_DEFAULT:-2}"
AWG_H3_DEFAULT="${AWG_H3_DEFAULT:-3}"
AWG_H4_DEFAULT="${AWG_H4_DEFAULT:-4}"

detect_openwrt_version() {
  AWG_OPENWRT_VERSION="$(. /etc/openwrt_release 2>/dev/null; printf "%s" "${DISTRIB_RELEASE:-}")"
  [ -n "$AWG_OPENWRT_VERSION" ] || AWG_OPENWRT_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /etc/openwrt_version 2>/dev/null | head -n1)"
  [ -n "$AWG_OPENWRT_VERSION" ] || fail "Не удалось определить версию OpenWrt для AmneziaWG"
}

detect_openwrt_arch() {
  AWG_OPENWRT_ARCH="$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch' 2>/dev/null)"
  [ -n "$AWG_OPENWRT_ARCH" ] || AWG_OPENWRT_ARCH="$(opkg print-architecture 2>/dev/null | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')"
  [ -n "$AWG_OPENWRT_ARCH" ] || AWG_OPENWRT_ARCH="$(opkg print-architecture 2>/dev/null | tail -n1 | awk '{print $2}')"
  [ -n "$AWG_OPENWRT_ARCH" ] || fail "Не удалось определить архитектуру OpenWrt для AmneziaWG"
}

detect_openwrt_target() {
  AWG_OPENWRT_TARGET="$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' 2>/dev/null)"
  [ -n "$AWG_OPENWRT_TARGET" ] || fail "Не удалось определить target OpenWrt для AmneziaWG"
  AWG_OPENWRT_TARGET_MAIN="$(printf "%s" "$AWG_OPENWRT_TARGET" | cut -d/ -f1)"
  AWG_OPENWRT_SUBTARGET="$(printf "%s" "$AWG_OPENWRT_TARGET" | cut -d/ -f2)"
  [ -n "$AWG_OPENWRT_TARGET_MAIN" ] || fail "Не удалось определить main target OpenWrt для AmneziaWG"
  [ -n "$AWG_OPENWRT_SUBTARGET" ] || fail "Не удалось определить subtarget OpenWrt для AmneziaWG"
}

resolve_awg_protocol_version() {
  major="$(printf "%s" "$AWG_OPENWRT_VERSION" | cut -d. -f1)"
  minor="$(printf "%s" "$AWG_OPENWRT_VERSION" | cut -d. -f2)"
  patch="$(printf "%s" "$AWG_OPENWRT_VERSION" | cut -d. -f3)"
  AWG_PROTOCOL_VERSION="1.0"

  if [ "$major" -gt 24 ] || \
     { [ "$major" -eq 24 ] && [ "$minor" -gt 10 ]; } || \
     { [ "$major" -eq 24 ] && [ "$minor" -eq 10 ] && [ "$patch" -ge 3 ]; } || \
     { [ "$major" -eq 23 ] && [ "$minor" -eq 5 ] && [ "$patch" -ge 6 ]; }
  then
    AWG_PROTOCOL_VERSION="2.0"
    AWG_LUCI_PACKAGE="luci-proto-amneziawg"
  else
    AWG_LUCI_PACKAGE="luci-app-amneziawg"
  fi
}

resolve_awg_package_source() {
  AWG_PACKAGE_SOURCE="${AWG_PACKAGE_SOURCE:-$AWG_PACKAGE_SOURCE_DEFAULT}"
  case "$AWG_PACKAGE_SOURCE" in
    slava-shchipunov)
      AWG_RELEASE_TAG="v${AWG_OPENWRT_VERSION}"
      AWG_RELEASE_BASE_URL="${AWG_REPO_BASE_SLAVA}/${AWG_RELEASE_TAG}"
      ;;
    *)
      fail "Неизвестный источник пакетов AmneziaWG: $AWG_PACKAGE_SOURCE"
      ;;
  esac
}

verify_awg_prereqs() {
  command -v ubus >/dev/null 2>&1 || fail "Для установки AmneziaWG нужен ubus"
  command -v jsonfilter >/dev/null 2>&1 || fail "Для установки AmneziaWG нужен jsonfilter"
  command -v wget >/dev/null 2>&1 || fail "Для установки AmneziaWG нужен wget"
  pkg_manager_is_opkg || fail "AmneziaWG install flow пока поддержан только на OpenWrt 24.10.x с opkg. Для 25.12.x нужна отдельная адаптация пакетов под apk."
}

awg_pkg_postfix() {
  printf "_v%s_%s_%s_%s" "$AWG_OPENWRT_VERSION" "$AWG_OPENWRT_ARCH" "$AWG_OPENWRT_TARGET_MAIN" "$AWG_OPENWRT_SUBTARGET"
}

is_awg_pkg_installed() {
  pkg_name="$1"
  opkg list-installed 2>/dev/null | grep -q "^${pkg_name} "
}

download_awg_package() {
  pkg_name="$1"
  pkg_file="${pkg_name}$(awg_pkg_postfix).ipk"
  pkg_url="${AWG_RELEASE_BASE_URL}/${pkg_file}"
  pkg_path="${AWG_STAGE_DIR}/${pkg_file}"

  wget -qO "$pkg_path" "$pkg_url" || return 1
  [ -s "$pkg_path" ] || return 1
  printf "%s" "$pkg_path"
}

install_awg_local_package() {
  pkg_path="$1"
  pkg_install_local_file "$pkg_path" || fail "Не удалось установить пакет AmneziaWG: $pkg_path"
}

verify_awg_install() {
  command -v awg >/dev/null 2>&1 || fail "После установки не найден бинарь awg"
  [ -f /lib/netifd/proto/amneziawg.sh ] || fail "После установки не найден netifd-протокол amneziawg"
}

download_and_install_awg_package() {
  pkg_name="$1"
  if is_awg_pkg_installed "$pkg_name"; then
    say "${GREEN}DONE${NC}  Пакет уже установлен: $pkg_name"
    return 0
  fi

  pkg_path="$(download_awg_package "$pkg_name")" || fail "Не удалось скачать пакет $pkg_name для OpenWrt ${AWG_OPENWRT_VERSION} / ${AWG_OPENWRT_ARCH} / ${AWG_OPENWRT_TARGET_MAIN}/${AWG_OPENWRT_SUBTARGET}"
  install_awg_local_package "$pkg_path"
  say "${GREEN}DONE${NC}  Установлен пакет: $pkg_name"
}

ensure_qrencode_installed() {
  if ! pkg_is_installed qrencode; then
    pkg_update_indexes >/dev/null 2>&1 || true
    pkg_install_packages qrencode || fail "Не удалось установить qrencode для AWG-клиентов"
  fi
}

awg_backend_notice() {
  say ""
  say "${YELLOW}INFO${NC}  Пробую backend AmneziaWG."
  say "Идём безопасным путём: сначала ставим exact-пакеты под эту OpenWrt, потом поднимаем awg0 и только после этого создаём клиентов."
}

install_amneziawg() {
  verify_awg_prereqs
  detect_openwrt_version
  detect_openwrt_arch
  detect_openwrt_target
  resolve_awg_protocol_version
  resolve_awg_package_source
  mkdir -p "$AWG_STAGE_DIR" || fail "Не удалось создать временный каталог для пакетов AmneziaWG"

  say ""
  say "=== AmneziaWG preflight ==="
  say "OpenWrt version: ${AWG_OPENWRT_VERSION}"
  say "Architecture: ${AWG_OPENWRT_ARCH}"
  say "Target: ${AWG_OPENWRT_TARGET_MAIN}/${AWG_OPENWRT_SUBTARGET}"
  say "AWG protocol generation: ${AWG_PROTOCOL_VERSION}"
  say "Package source: ${AWG_PACKAGE_SOURCE}"
  say "Expected release tag: ${AWG_RELEASE_TAG}"
  say "Release base URL: ${AWG_RELEASE_BASE_URL}"
  say ""

  download_and_install_awg_package "kmod-amneziawg"
  download_and_install_awg_package "amneziawg-tools"
  download_and_install_awg_package "$AWG_LUCI_PACKAGE"
  ensure_qrencode_installed
  verify_awg_install
  rm -rf "$AWG_STAGE_DIR" 2>/dev/null || true
  done_ "AmneziaWG пакеты установлены"
}

ensure_awg_dirs() {
  mkdir -p "$AWG_SERVER_DIR" "$AWG_CLIENT_DIR" || fail "Не удалось создать каталоги AmneziaWG"
}

awg_keygen() {
  command -v awg >/dev/null 2>&1 || fail "Не найден awg после установки пакетов"
}

ensure_awg_server_keys() {
  ensure_awg_dirs
  if [ ! -f "$AWG_SERVER_DIR/server.key" ]; then
    umask 077
    awg genkey | tee "$AWG_SERVER_DIR/server.key" | awg pubkey > "$AWG_SERVER_DIR/server.pub"
  fi
}

ensure_awg_obfuscation_defaults() {
  AWG_JC="${AWG_JC:-$AWG_JC_DEFAULT}"
  AWG_JMIN="${AWG_JMIN:-$AWG_JMIN_DEFAULT}"
  AWG_JMAX="${AWG_JMAX:-$AWG_JMAX_DEFAULT}"
  AWG_S1="${AWG_S1:-$AWG_S1_DEFAULT}"
  AWG_S2="${AWG_S2:-$AWG_S2_DEFAULT}"
  AWG_H1="${AWG_H1:-$AWG_H1_DEFAULT}"
  AWG_H2="${AWG_H2:-$AWG_H2_DEFAULT}"
  AWG_H3="${AWG_H3:-$AWG_H3_DEFAULT}"
  AWG_H4="${AWG_H4:-$AWG_H4_DEFAULT}"
}

ensure_awg_endpoint() {
  if [ -z "${AWG_ENDPOINT:-}" ]; then
    ask "Endpoint для private-клиентов AmneziaWG (например: my.domain.com:${AWG_LISTEN_PORT})" AWG_ENDPOINT ""
    [ -n "$AWG_ENDPOINT" ] || fail "Endpoint для private-клиентов пустой"
    conf_set AWG_ENDPOINT "$AWG_ENDPOINT"
  fi
}

amneziawg_server_ready() {
  command -v awg >/dev/null 2>&1 || return 1
  [ -f "$AWG_SERVER_DIR/server.key" ] || return 1
  [ -f "$AWG_SERVER_DIR/server.pub" ] || return 1
  uci -q get network."$AWG_IFACE".proto 2>/dev/null | grep -qx 'amneziawg' || return 1
  [ -n "${AWG_ENDPOINT:-}" ] || return 1
  return 0
}

amneziawg_interface_running() {
  command -v ip >/dev/null 2>&1 || return 0
  ip link show "$AWG_IFACE" >/dev/null 2>&1
}

amneziawg_require_server_ready() {
  if ! amneziawg_server_ready; then
    fail "AmneziaWG server не готов. Сначала запусти пункт 5: Доустановить Amnezia в Podkop."
  fi

  if ! amneziawg_interface_running; then
    /etc/init.d/network restart >/dev/null 2>&1 || true
    sleep 2
    amneziawg_interface_running || fail "AmneziaWG server настроен, но интерфейс ${AWG_IFACE} не поднят. Проверь /etc/config/network и system log."
  fi
}

amneziawg_validate_client_name() {
  name="$1"
  [ -n "$name" ] || return 1
  printf "%s" "$name" | grep -Eq '^[A-Za-z0-9._-]{1,32}$'
}

amneziawg_client_exists() {
  name="$1"
  [ -f "$AWG_CLIENT_DIR/$name.conf" ] && return 0
  [ -n "$(awg_find_section_by_name "$name")" ] && return 0
  return 1
}

find_lan_zone_name() {
  uci show firewall | grep "=zone" | cut -d. -f2 | while read -r z; do
    name="$(uci -q get firewall."$z".name || true)"
    [ "$name" = "lan" ] && echo "$z" && break
  done
}

configure_awg_firewall() {
  lan_zone="$(find_lan_zone_name)"
  [ -n "$lan_zone" ] || fail "Не нашёл firewall zone 'lan'"

  if ! uci -q get firewall."$lan_zone".network 2>/dev/null | grep -qw "$AWG_IFACE"; then
    uciq add_list firewall."$lan_zone".network="$AWG_IFACE"
  fi

  uci -q delete firewall.awg_allow >/dev/null 2>&1 || true
  uciq set firewall.awg_allow='rule'
  uciq set firewall.awg_allow.name='Allow-AmneziaWG-Inbound'
  uciq set firewall.awg_allow.src='wan'
  uciq set firewall.awg_allow.proto='udp'
  uciq set firewall.awg_allow.dest_port="$AWG_LISTEN_PORT"
  uciq set firewall.awg_allow.target='ACCEPT'

  has_fwd="$(uci show firewall | grep "=forwarding" | grep -q "src='lan'.*dest='wan'" && echo 1 || echo 0)"
  if [ "$has_fwd" = "0" ]; then
    f="$(uci add firewall forwarding)"
    uciq set firewall."$f".src='lan'
    uciq set firewall."$f".dest='wan'
  fi

  uciq commit firewall
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
}

configure_amneziawg_server() {
  awg_keygen
  ensure_awg_server_keys
  ensure_awg_obfuscation_defaults
  ensure_awg_endpoint

  uciq set network."$AWG_IFACE"='interface'
  uciq set network."$AWG_IFACE".proto='amneziawg'
  uciq set network."$AWG_IFACE".private_key="$(cat "$AWG_SERVER_DIR/server.key")"
  uciq set network."$AWG_IFACE".listen_port="$AWG_LISTEN_PORT"
  uciq set network."$AWG_IFACE".defaultroute='0'
  uciq -q del network."$AWG_IFACE".addresses
  uciq add_list network."$AWG_IFACE".addresses="${AWG_SERVER_IP}/24"
  uciq set network."$AWG_IFACE".awg_jc="$AWG_JC"
  uciq set network."$AWG_IFACE".awg_jmin="$AWG_JMIN"
  uciq set network."$AWG_IFACE".awg_jmax="$AWG_JMAX"
  uciq set network."$AWG_IFACE".awg_s1="$AWG_S1"
  uciq set network."$AWG_IFACE".awg_s2="$AWG_S2"
  uciq set network."$AWG_IFACE".awg_h1="$AWG_H1"
  uciq set network."$AWG_IFACE".awg_h2="$AWG_H2"
  uciq set network."$AWG_IFACE".awg_h3="$AWG_H3"
  uciq set network."$AWG_IFACE".awg_h4="$AWG_H4"
  uciq commit network

  configure_awg_firewall
  /etc/init.d/network restart >/dev/null 2>&1 || true

  sleep 2
  ip a show "$AWG_IFACE" >/dev/null 2>&1 || warn "Интерфейс ${AWG_IFACE} пока не виден в ip a. Это может быть нормально до первого клиента."
  done_ "Private server ${AWG_IFACE} настроен (AmneziaWG)"
}

awg_peer_section_list() {
  uci show network 2>/dev/null | grep "=amneziawg_${AWG_IFACE}" | cut -d. -f2
}

awg_find_section_by_name() {
  name="$1"
  awg_peer_section_list | while read -r sec; do
    desc="$(uci -q get network."$sec".description || uci -q get network."$sec".name || true)"
    [ "$desc" = "$name" ] && { echo "$sec"; break; }
  done
}

awg_next_free_ip32() {
  used="$(uci show network 2>/dev/null | sed -n "s/.*'\(${AWG_SERVER_NET_PREFIX}\.[0-9]\+\)\/32'.*/\1/p")"
  i=2
  while [ "$i" -le 254 ]; do
    ip="${AWG_SERVER_NET_PREFIX}.${i}"
    echo "$used" | grep -qx "$ip" || { echo "$ip/32"; return 0; }
    i=$((i+1))
  done
  return 1
}

create_amneziawg_peer_config() {
  name="$1"
  client_priv="$2"
  client_ip32="$3"
  client_psk="$4"
  file="$AWG_CLIENT_DIR/$name.conf"

  cat > "$file" <<EOF
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
EOF
}

create_amneziawg_peer() {
  name="$1"
  client_ip32="$2"

  [ -n "$name" ] || fail "Имя AWG-клиента пустое"
  [ -n "$client_ip32" ] || fail "IP AWG-клиента пустой"
  amneziawg_validate_client_name "$name" || fail "Имя клиента должно быть 1-32 символа: латиница, цифры, точка, подчёркивание или дефис"
  amneziawg_require_server_ready
  amneziawg_client_exists "$name" && fail "Клиент уже существует: $name"
  ensure_awg_server_keys
  ensure_awg_obfuscation_defaults
  ensure_awg_endpoint
  mkdir -p "$AWG_CLIENT_DIR" || fail "Не удалось создать каталог AWG-клиентов"

  umask 077
  client_priv="$(awg genkey)"
  client_pub="$(printf "%s" "$client_priv" | awg pubkey)"
  client_psk="$(awg genpsk)"

  sec="$(uci add network "amneziawg_${AWG_IFACE}")"
  uciq set network."$sec".description="$name"
  uciq set network."$sec".public_key="$client_pub"
  uciq set network."$sec".preshared_key="$client_psk"
  uciq set network."$sec".route_allowed_ips='0'
  uciq set network."$sec".persistent_keepalive='25'
  uciq add_list network."$sec".allowed_ips="$client_ip32"
  uciq commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true

  create_amneziawg_peer_config "$name" "$client_priv" "$client_ip32" "$client_psk"

  say ""
  say "${GREEN}QR (ANSI) для private-клиента $name:${NC}"
  qrencode -t ansiutf8 < "$AWG_CLIENT_DIR/$name.conf" || true
  done_ "Private-клиент $name создан: $AWG_CLIENT_DIR/$name.conf"
}

amneziawg_clients_list() {
  amneziawg_require_server_ready
  say ""
  say "=== Private clients (${AWG_IFACE}) ==="
  awg_peer_section_list | while read -r sec; do
    [ -n "$sec" ] || continue
    desc="$(uci -q get network."$sec".description || uci -q get network."$sec".name || true)"
    ips="$(uci -q get network."$sec".allowed_ips || true)"
    [ -z "$desc" ] && desc="(no description)"
    say " - ${GREEN}${desc}${NC}  [$sec]  allowed_ips: ${ips:-none}"
  done
  say ""
}

amneziawg_show_conf_text() {
  amneziawg_require_server_ready
  name="$1"
  file="$AWG_CLIENT_DIR/$name.conf"
  [ -f "$file" ] || fail "Файл конфига не найден: $file"
  say ""
  say "=== $file ==="
  cat "$file"
  say ""
}

amneziawg_show_conf_qr() {
  amneziawg_require_server_ready
  name="$1"
  file="$AWG_CLIENT_DIR/$name.conf"
  [ -f "$file" ] || fail "Файл конфига не найден: $file"
  say ""
  say "${GREEN}QR (ANSI) для private-клиента $name:${NC}"
  qrencode -t ansiutf8 < "$file" || fail "qrencode не сработал (проверь пакет qrencode)"
  say ""
}

amneziawg_create_client() {
  amneziawg_require_server_ready
  mkdir -p "$AWG_CLIENT_DIR"
  [ -f "$AWG_SERVER_DIR/server.pub" ] || fail "Не найден $AWG_SERVER_DIR/server.pub (сервер AWG не настроен?)"

  ask "Имя нового private-клиента (латиница, без пробелов)" name ""
  amneziawg_validate_client_name "$name" || fail "Имя клиента должно быть 1-32 символа: латиница, цифры, точка, подчёркивание или дефис"
  amneziawg_client_exists "$name" && fail "Клиент уже существует: $name"

  ip32="$(awg_next_free_ip32)" || fail "Не нашёл свободный IP в ${AWG_SERVER_NET_PREFIX}.0/24"
  create_amneziawg_peer "$name" "$ip32"
}

amneziawg_delete_client() {
  amneziawg_require_server_ready
  ask "Имя private-клиента для удаления" name ""
  [ -n "$name" ] || fail "Имя пустое"

  sec="$(awg_find_section_by_name "$name")"
  [ -n "$sec" ] || fail "Не нашёл клиента '$name' в UCI"

  uciq delete network."$sec"
  uciq commit network
  /etc/init.d/network restart >/dev/null 2>&1 || true

  rm -f "$AWG_CLIENT_DIR/$name.conf" 2>/dev/null || true
  done_ "Private-клиент удалён: $name"
}

amneziawg_manage_menu() {
  while true; do
    say ""
    say "=== Управление Private / Amnezia (${AWG_IFACE}) ==="
    say "1) Показать список клиентов"
    say "2) Показать QR для клиента"
    say "3) Показать текстовый конфиг клиента"
    say "4) Создать нового клиента"
    say "5) Удалить клиента"
    say "0) Назад"
    ask "Выбор" act "1"

    case "$act" in
      1) amneziawg_clients_list ;;
      2) ask "Имя клиента" n ""; amneziawg_show_conf_qr "$n" ;;
      3) ask "Имя клиента" n ""; amneziawg_show_conf_text "$n" ;;
      4) amneziawg_create_client ;;
      5) amneziawg_delete_client ;;
      0) break ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}
