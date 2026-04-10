check_openwrt() {
  rel="$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE" 2>/dev/null || true)"
  echo "$rel" | grep -q "^24\.10" || fail "Нужен OpenWrt 24.10.x (сейчас: ${rel:-unknown})."
  done_ "OpenWrt версия: $rel"
}

check_inet() {
  ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || fail "Нет интернета (ping 1.1.1.1)."
  wget -q --spider https://downloads.openwrt.org/ || fail "Нет DNS/TLS (wget https://downloads.openwrt.org)."
  done_ "Интернет + HTTPS OK"
}

sync_time() {
  ntpd -q -p 0.openwrt.pool.ntp.org >/dev/null 2>&1 || warn "NTP не сработал (продолжаю)."
  done_ "Время проверено"
}

install_full_pkg_list() {
  opkg update
  opkg install \
    parted losetup resize2fs blkid e2fsprogs block-mount fstrim tune2fs \
    ca-bundle ca-certificates wget-ssl curl nano-full tcpdump kmod-nft-tproxy ss
  done_ "Установлен полный список пакетов"
}

overlay_report_and_ask_expand() {
  set -- $(df -k /overlay 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
  total_kb="${1:-0}"
  used_kb="${2:-0}"
  avail_kb="${3:-0}"

  total_mb=$((total_kb/1024))
  used_mb=$((used_kb/1024))
  avail_mb=$((avail_kb/1024))

  say ""
  say "Overlay (место под пакеты): всего ${total_mb}MB, занято ${used_mb}MB, свободно ${avail_mb}MB"
  say ""

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
