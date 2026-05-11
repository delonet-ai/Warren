GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"
WARREN_TIME_MIN_EPOCH="${WARREN_TIME_MIN_EPOCH:-1735689600}"
WARREN_TIME_MAX_EPOCH="${WARREN_TIME_MAX_EPOCH:-2082758400}"

say() {
  printf "%b\n" "$*"
}

done_() {
  say "${GREEN}DONE${NC}  $*"
  case "${MODE:-}" in
    initialize|vps|podkop_backup|qos_private|amnezia_client_create|amnezia_client_delete|remote_admin|usb_modem|tg_bot|diagnostics|diagnostics_emergency|manage_private|sni_checker|rf_bundle_wip|naiveproxy_wip|shadowsocks_fallback_wip)
      ;;
    *)
      print_progress
      ;;
  esac
  sleep 5
}

info() {
  say "${YELLOW}INFO${NC}  $*"
}

warn() {
  say "${YELLOW}WARN${NC}  $*"
  sleep 5
}

fail() {
  say "${RED}FAIL${NC}  $*"
  exit 1
}

log() {
  echo "[$(date +'%F %T')] $*" >> "$LOG"
}

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
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

uciq() {
  uci -q "$@"
}

proxy_link_supported() {
  printf "%s" "$1" | grep -Eq '^(vless|ss|trojan|socks4|socks5|hy2|hysteria2)://'
}

detect_pkg_manager() {
  if command -v apk >/dev/null 2>&1; then
    printf "%s" "apk"
    return 0
  fi
  if command -v opkg >/dev/null 2>&1; then
    printf "%s" "opkg"
    return 0
  fi
  return 1
}

pkg_manager() {
  if [ -n "${WARREN_PKG_MANAGER:-}" ]; then
    printf "%s" "$WARREN_PKG_MANAGER"
    return 0
  fi

  WARREN_PKG_MANAGER="$(detect_pkg_manager)" || return 1
  printf "%s" "$WARREN_PKG_MANAGER"
}

pkg_manager_is_apk() {
  [ "$(pkg_manager 2>/dev/null)" = "apk" ]
}

pkg_manager_is_opkg() {
  [ "$(pkg_manager 2>/dev/null)" = "opkg" ]
}

openwrt_release_version() {
  if [ -n "${WARREN_OPENWRT_RELEASE:-}" ]; then
    printf "%s" "$WARREN_OPENWRT_RELEASE"
    return 0
  fi

  WARREN_OPENWRT_RELEASE="$(. /etc/openwrt_release 2>/dev/null; printf "%s" "${DISTRIB_RELEASE:-}")"
  if [ -z "$WARREN_OPENWRT_RELEASE" ]; then
    WARREN_OPENWRT_RELEASE="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' /etc/openwrt_version 2>/dev/null | head -n1)"
  fi

  printf "%s" "$WARREN_OPENWRT_RELEASE"
}

openwrt_release_supported() {
  rel="$(openwrt_release_version)"
  printf "%s" "$rel" | grep -Eq '^(24\.10|25\.12)(\.|$)'
}

pkg_is_installed() {
  pkg="$1"

  if pkg_manager_is_opkg; then
    opkg list-installed 2>/dev/null | grep -q "^${pkg} "
    return "$?"
  fi

  if pkg_manager_is_apk; then
    apk info -e "$pkg" >/dev/null 2>&1 && return 0
    apk list -I "$pkg" 2>/dev/null | grep -q "^${pkg}-"
    return "$?"
  fi

  return 1
}

pkg_update_indexes() {
  if pkg_manager_is_opkg; then
    opkg update
    return "$?"
  fi

  if pkg_manager_is_apk; then
    apk update
    return "$?"
  fi

  fail "Не найден поддерживаемый пакетный менеджер OpenWrt (opkg/apk)."
}

pkg_install_packages() {
  [ "$#" -gt 0 ] || return 0

  if pkg_manager_is_opkg; then
    opkg install "$@"
    return "$?"
  fi

  if pkg_manager_is_apk; then
    apk add "$@"
    return "$?"
  fi

  fail "Не найден поддерживаемый пакетный менеджер OpenWrt (opkg/apk)."
}

pkg_install_local_file() {
  pkg_path="$1"
  [ -n "$pkg_path" ] || return 1

  if pkg_manager_is_opkg; then
    opkg install "$pkg_path"
    return "$?"
  fi

  if pkg_manager_is_apk; then
    apk add --allow-untrusted "$pkg_path"
    return "$?"
  fi

  fail "Не найден поддерживаемый пакетный менеджер OpenWrt (opkg/apk)."
}

pkg_ensure_installed() {
  missing=""

  for pkg in "$@"; do
    [ -n "$pkg" ] || continue
    pkg_is_installed "$pkg" || missing="$missing $pkg"
  done

  [ -n "$missing" ] || return 0

  pkg_update_indexes || fail "Не удалось обновить индексы пакетов через $(pkg_manager)."
  # shellcheck disable=SC2086
  pkg_install_packages $missing || fail "Не удалось установить пакеты:$missing"
}

warren_now_epoch() {
  date +%s 2>/dev/null || echo 0
}

warren_time_sane() {
  now="$(warren_now_epoch)"
  if [ "${now:-0}" -ge "$WARREN_TIME_MIN_EPOCH" ] && [ "${now:-0}" -le "$WARREN_TIME_MAX_EPOCH" ]; then
    return 0
  fi
  return 1
}

warren_set_timezone_moscow() {
  uci -q batch <<'EOF' >/dev/null 2>&1 || return 1
set system.@system[0].timezone='MSK-3'
set system.@system[0].zonename='Europe/Moscow'
commit system
EOF
}

warren_set_time_from_epoch() {
  browser_epoch="$1"
  case "$browser_epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$browser_epoch" -ge "$WARREN_TIME_MIN_EPOCH" ] || return 1
  [ "$browser_epoch" -le "$WARREN_TIME_MAX_EPOCH" ] || return 1
  date -u -s "@$browser_epoch" >/dev/null 2>&1
}

warren_restart_ntp() {
  if [ -x /etc/init.d/sysntpd ]; then
    /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
    /etc/init.d/sysntpd restart >/dev/null 2>&1 || true
  fi
}

warren_ntp_sync_once() {
  if command -v ntpd >/dev/null 2>&1; then
    ntpd -q -p 0.openwrt.pool.ntp.org >/dev/null 2>&1 && return 0
  fi
  if [ -x /etc/init.d/sysntpd ]; then
    /etc/init.d/sysntpd restart >/dev/null 2>&1 || true
  fi
  sleep 3
  warren_time_sane
}

warren_require_sane_time() {
  context="${1:-этого шага}"
  warren_time_sane || fail "Неверное системное время. Исправь время роутера перед запуском ${context}: иначе DNS/TLS и Podkop будут ломаться."
}
