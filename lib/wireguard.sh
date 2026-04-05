WG_NET_PREFIX="10.10.10"
WG_SERVER_IP="${WG_NET_PREFIX}.1"
WG_CLIENT_DIR="/etc/wireguard/clients"

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

  uciq set network.wg0='interface'
  uciq set network.wg0.proto='wireguard'
  uciq set network.wg0.private_key="$(cat /etc/wireguard/server.key)"
  uciq set network.wg0.listen_port='51820'
  uciq set network.wg0.defaultroute='0'
  uciq -q del network.wg0.addresses
  uciq add_list network.wg0.addresses='10.10.10.1/24'
  uciq commit network

  uci -q delete firewall.wg >/dev/null 2>&1 || true
  uci -q delete firewall.wg_wan >/dev/null 2>&1 || true
  uci -q delete firewall.wg_in >/dev/null 2>&1 || true

  lan_zone="$(uci show firewall | grep "=zone" | cut -d. -f2 | while read -r z; do
    name="$(uci -q get firewall."$z".name || true)"
    [ "$name" = "lan" ] && echo "$z" && break
  done)"

  [ -n "$lan_zone" ] || fail "Не нашёл firewall zone 'lan'"

  if ! uci -q get firewall."$lan_zone".network 2>/dev/null | grep -qw 'wg0'; then
    uciq add_list firewall."$lan_zone".network='wg0'
  fi

  uciq set firewall.wg_allow='rule'
  uciq set firewall.wg_allow.name='Allow-WireGuard-Inbound'
  uciq set firewall.wg_allow.src='wan'
  uciq set firewall.wg_allow.proto='udp'
  uciq set firewall.wg_allow.dest_port='51820'
  uciq set firewall.wg_allow.target='ACCEPT'

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
  name="$1"
  ip="$2"
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

  if [ -z "${WG_ENDPOINT:-}" ]; then
    ask "Endpoint для клиентов (например: my.domain.com:51820)" WG_ENDPOINT ""
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

wg_clients_list() {
  say ""
  say "=== WireGuard клиенты (wg0) ==="
  uci show network 2>/dev/null | grep "=wireguard_wg0" | cut -d. -f2 | while read -r sec; do
    desc="$(uci -q get network."$sec".description || true)"
    ips="$(uci -q get network."$sec".allowed_ips || true)"
    [ -z "$desc" ] && desc="(no description)"
    say " - ${GREEN}${desc}${NC}  [$sec]  allowed_ips: ${ips:-none}"
  done
  say ""
}

wg_find_section_by_name() {
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
