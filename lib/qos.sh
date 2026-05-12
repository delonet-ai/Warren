QOS_STATE_FILE="${QOS_STATE_FILE:-/etc/warren/amnezia-qos.tsv}"
QOS_INIT_SCRIPT="${QOS_INIT_SCRIPT:-/etc/init.d/warren-qos}"

qos_profile_dscp() {
  case "$1" in
    standard) printf "%s" "cs0" ;;
    priority) printf "%s" "cs5" ;;
    bulk) printf "%s" "cs1" ;;
    limit_1mbit) printf "%s" "cs0" ;;
    limit_10mbit) printf "%s" "cs0" ;;
    *) return 1 ;;
  esac
}

qos_profile_limit_kbytes() {
  case "$1" in
    limit_1mbit) printf "%s" "125" ;;
    limit_10mbit) printf "%s" "1250" ;;
    *) return 1 ;;
  esac
}

qos_profile_label() {
  case "$1" in
    standard) printf "%s" "standard / обычный" ;;
    priority) printf "%s" "priority / высокий приоритет" ;;
    bulk) printf "%s" "bulk / фоновый" ;;
    limit_1mbit) printf "%s" "limit-1 / DSCP cs0 + 1 Mbps up/down" ;;
    limit_10mbit) printf "%s" "limit-10 / DSCP cs0 + 10 Mbps up/down" ;;
    off) printf "%s" "off / снять профиль" ;;
    *) printf "%s" "$1" ;;
  esac
}

qos_client_ip_by_name() {
  target="$1"
  amneziawg_clients_tsv | while IFS='	' read -r name ips sec conf_file; do
    [ "$name" = "$target" ] || continue
    first_ip="$(printf "%s" "$ips" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$' | head -n1)"
    [ -n "$first_ip" ] && { printf "%s" "$first_ip"; break; }
  done
}

qos_assignment_profile() {
  target="$1"
  [ -f "$QOS_STATE_FILE" ] || return 1
  awk -F '	' -v target="$target" '$1 == target { profile=$3 } END { if (profile != "") print profile }' "$QOS_STATE_FILE"
}

qos_remove_client() {
  target="$1"
  [ -n "$target" ] || return 0
  [ -f "$QOS_STATE_FILE" ] || return 0

  tmp="${QOS_STATE_FILE}.tmp.$$"
  awk -F '	' -v target="$target" '$1 != target' "$QOS_STATE_FILE" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv "$tmp" "$QOS_STATE_FILE"
}

qos_set_assignment() {
  name="$1"
  ip32="$2"
  profile="$3"

  amneziawg_validate_client_name "$name" || fail "Имя клиента должно быть 1-32 символа: латиница, цифры, точка, подчёркивание или дефис"
  [ -n "$ip32" ] || fail "Не нашёл IP клиента $name"
  qos_profile_dscp "$profile" >/dev/null || fail "Неизвестный QoS-профиль: $profile"

  mkdir -p "$(dirname "$QOS_STATE_FILE")" || fail "Не удалось создать каталог QoS"
  tmp="${QOS_STATE_FILE}.tmp.$$"
  [ -f "$QOS_STATE_FILE" ] && awk -F '	' -v target="$name" '$1 != target' "$QOS_STATE_FILE" > "$tmp" || : > "$tmp"
  printf "%s\t%s\t%s\n" "$name" "$ip32" "$profile" >> "$tmp"
  mv "$tmp" "$QOS_STATE_FILE" || fail "Не удалось сохранить QoS-профиль"
  chmod 600 "$QOS_STATE_FILE" 2>/dev/null || true
}

qos_ensure_init_script() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  [ -x /usr/bin/warren ] || return 0

  cat > "$QOS_INIT_SCRIPT" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
  /usr/bin/warren --apply-qos >/tmp/warren-qos.log 2>&1
}
EOF
  chmod 755 "$QOS_INIT_SCRIPT" 2>/dev/null || true
  "$QOS_INIT_SCRIPT" enable >/dev/null 2>&1 || true
}

qos_apply_rules() {
  command -v nft >/dev/null 2>&1 || fail "Для QoS нужен nft. Установи пакет nftables/nftables-json через базовую установку Warren."

  nft delete table inet warren_qos >/dev/null 2>&1 || true
  nft add table inet warren_qos || fail "Не удалось создать nft table inet warren_qos"
  nft add chain inet warren_qos prerouting '{ type filter hook prerouting priority mangle; policy accept; }' || fail "Не удалось создать nft chain warren_qos/prerouting"

  [ -f "$QOS_STATE_FILE" ] || return 0
  while IFS='	' read -r q_name q_ip32 q_profile; do
    [ -n "$q_name" ] || continue
    dscp="$(qos_profile_dscp "$q_profile")" || continue
    ip="${q_ip32%/32}"
    printf "%s" "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
    nft_comment="warren_${q_name}_${q_profile}"
    nft add rule inet warren_qos prerouting ip saddr "$ip" ip dscp set "$dscp" comment "$nft_comment" >/dev/null 2>&1 || warn "Не удалось добавить QoS-правило для $q_name"
    if limit_kbytes="$(qos_profile_limit_kbytes "$q_profile" 2>/dev/null)"; then
      nft add rule inet warren_qos prerouting ip saddr "$ip" limit rate over "$limit_kbytes" kbytes/second drop comment "${nft_comment}_up" >/dev/null 2>&1 || warn "Не удалось добавить upload-limit для $q_name"
      nft add rule inet warren_qos prerouting ip daddr "$ip" limit rate over "$limit_kbytes" kbytes/second drop comment "${nft_comment}_down" >/dev/null 2>&1 || warn "Не удалось добавить download-limit для $q_name"
    fi
  done < "$QOS_STATE_FILE"
}

run_qos_apply_only() {
  qos_apply_rules
}

qos_print_assignments() {
  say ""
  say "=== QoS профили Amnezia ==="
  if [ ! -f "$QOS_STATE_FILE" ] || [ ! -s "$QOS_STATE_FILE" ]; then
    say "Профили пока не назначены."
    return 0
  fi
  while IFS='	' read -r q_name q_ip32 q_profile; do
    [ -n "$q_name" ] || continue
    say " - ${GREEN}${q_name}${NC}  ${q_ip32:-no-ip}  $(qos_profile_label "$q_profile")"
  done < "$QOS_STATE_FILE"
}

run_qos_flow() {
  amneziawg_require_server_ready

  name="${QOS_CLIENT_NAME:-${AMZ_CLIENT_NAME:-}}"
  profile="${QOS_PROFILE:-}"

  if [ -z "$name" ] && [ "${WARREN_LUCI_REQUEST:-0}" != "1" ]; then
    amneziawg_clients_list
    ask "Имя Amnezia-клиента для QoS" name ""
  fi

  if [ -z "$profile" ] && [ "${WARREN_LUCI_REQUEST:-0}" != "1" ]; then
    say ""
    say "Профили QoS:"
    say "1) standard — обычный трафик"
    say "2) priority — высокий приоритет"
    say "3) bulk — фоновый трафик"
    say "4) limit-1 — обычный DSCP cs0 + лимит 1 Mbps up/down"
    say "5) limit-10 — обычный DSCP cs0 + лимит 10 Mbps up/down"
    say "0) off — снять профиль"
    ask "Выбор профиля" choice "1"
    case "$choice" in
      1|standard) profile="standard" ;;
      2|priority) profile="priority" ;;
      3|bulk) profile="bulk" ;;
      4|limit-1|limit_1mbit) profile="limit_1mbit" ;;
      5|limit-10|limit_10mbit) profile="limit_10mbit" ;;
      0|off) profile="off" ;;
      *) fail "Неверный профиль QoS: $choice" ;;
    esac
  fi

  [ -n "$name" ] || fail "Не задан Amnezia-клиент для QoS"
  [ -n "$profile" ] || fail "Не задан QoS-профиль"

  if [ "$profile" = "off" ]; then
    qos_remove_client "$name"
    qos_apply_rules
    qos_ensure_init_script
    qos_print_assignments
    done_ "QoS-профиль снят: $name"
    return 0
  fi

  ip32="$(qos_client_ip_by_name "$name")"
  [ -n "$ip32" ] || fail "Не нашёл Amnezia-клиента или его /32 IP: $name"
  qos_set_assignment "$name" "$ip32" "$profile"
  qos_apply_rules
  qos_ensure_init_script
  qos_print_assignments
  done_ "QoS-профиль применён: $name -> $(qos_profile_label "$profile")"
}
