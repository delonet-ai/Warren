GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"
WARREN_TIME_MIN_EPOCH="${WARREN_TIME_MIN_EPOCH:-1735689600}"
WARREN_TIME_MAX_EPOCH="${WARREN_TIME_MAX_EPOCH:-2082758400}"

say() {
  printf "%b\n" "$*"
}

warren_done_sleep() {
  [ "${WARREN_LUCI_REQUEST:-0}" = "1" ] && return 0
  sleep "${WARREN_DONE_SLEEP:-5}"
}

warren_warn_sleep() {
  [ "${WARREN_LUCI_REQUEST:-0}" = "1" ] && return 0
  sleep "${WARREN_WARN_SLEEP:-5}"
}

done_() {
  say "${GREEN}DONE${NC}  $*"
  case "${MODE:-}" in
    initialize|vps|podkop_backup|qos_private|amnezia_client_create|amnezia_client_delete|remote_admin|remote_admin_config|remote_admin_poll_now|remote_admin_router_install|remote_admin_vps_install|watchdog_enable|watchdog_disable|watchdog_reset|usb_modem|tg_bot|diagnostics|diagnostics_emergency|manage_private|sni_checker|sni_apply|rf_bundle_wip|naiveproxy_wip|shadowsocks_fallback_wip)
      ;;
    *)
      print_progress
      ;;
  esac
  warren_done_sleep
}

info() {
  say "${YELLOW}INFO${NC}  $*"
}

warn() {
  say "${YELLOW}WARN${NC}  $*"
  warren_warn_sleep
}

fail() {
  say "${RED}FAIL${NC}  $*"
  exit 1
}

log() {
  _wlog_message="$*"
  _wlog_upper="$(printf "%s" "$_wlog_message" | tr '[:lower:]' '[:upper:]')"
  case "$_wlog_upper" in
    *PASSWORD*|*TOKEN*|*SECRET*)
      _wlog_message="*** sensitive message redacted ***"
      ;;
  esac
  printf "[%s] %s\n" "$(date +'%F %T')" "$_wlog_message" >> "$LOG"
}

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

if ! command -v warren_retry_delay >/dev/null 2>&1; then
  warren_retry_delay() {
    case "$1" in
      2) printf "%s" "5" ;;
      3) printf "%s" "15" ;;
      *) printf "%s" "0" ;;
    esac
  }
fi

if ! command -v warren_sha256_file >/dev/null 2>&1; then
  warren_sha256_file() {
    command -v sha256sum >/dev/null 2>&1 || return 1
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  }
fi

if ! command -v warren_verify_file_hash >/dev/null 2>&1; then
  warren_verify_file_hash() {
    _wvfh_file="$1"
    _wvfh_expected="${2:-}"
    _wvfh_label="${3:-$1}"

    [ "${WARREN_SKIP_HASH_CHECK:-0}" = "1" ] && return 0
    [ -n "$_wvfh_expected" ] || return 1
    _wvfh_actual="$(warren_sha256_file "$_wvfh_file")" || return 1
    if [ "$_wvfh_actual" != "$_wvfh_expected" ]; then
      printf "%s\n" \
        "SHA256 mismatch для $_wvfh_label: ожидался $_wvfh_expected, получен ${_wvfh_actual:-unknown}" >&2
      return 1
    fi
    return 0
  }
fi

if ! command -v warren_manifest_sha >/dev/null 2>&1; then
  warren_manifest_sha() {
    _wms_manifest="$1"
    _wms_path="$2"
    [ -r "$_wms_manifest" ] || return 1
    awk -v path="$_wms_path" '
      NF == 2 && $2 == path && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
        print tolower($1)
        found = 1
        exit
      }
      END { if (!found) exit 1 }
    ' "$_wms_manifest"
  }
fi

# wget with an inactivity timeout. GNU wget-ssl (installed by basic) otherwise
# waits 900s per read and retries 20 times; Warren retries on its own.
if ! command -v warren_wget >/dev/null 2>&1; then
  warren_wget() {
    # Not cached: basic replaces uclient-fetch with wget-ssl mid-run.
    if wget --version 2>/dev/null | grep -q 'GNU Wget'; then
      wget -T "${WARREN_WGET_TIMEOUT:-20}" --tries=1 "$@"
    else
      wget -T "${WARREN_WGET_TIMEOUT:-20}" "$@"
    fi
  }
fi

if ! command -v warren_download_retry >/dev/null 2>&1; then
  warren_download_retry() {
    _wdr_url="$1"
    _wdr_out="$2"
    _wdr_expected="${3:-}"
    _wdr_label="${4:-$1}"
    _wdr_attempt=1

    while [ "$_wdr_attempt" -le 3 ]; do
      if [ "$_wdr_attempt" -gt 1 ]; then
        _wdr_delay="$(warren_retry_delay "$_wdr_attempt")"
        printf "%s\n" \
          "Повтор загрузки ${_wdr_attempt}/3: $_wdr_label (задержка ${_wdr_delay}s)" >&2
        sleep "$_wdr_delay"
      fi
      rm -f "$_wdr_out" 2>/dev/null || true
      if warren_wget -qO "$_wdr_out" "$_wdr_url" 2>/dev/null; then
        if [ "${WARREN_SKIP_HASH_CHECK:-0}" = "1" ] || [ -z "$_wdr_expected" ]; then
          return 0
        fi
        if warren_verify_file_hash "$_wdr_out" "$_wdr_expected" "$_wdr_label"; then
          return 0
        fi
      fi
      _wdr_attempt=$((_wdr_attempt + 1))
    done
    rm -f "$_wdr_out" 2>/dev/null || true
    return 1
  }
fi

warren_wget_retry() {
  _wwr_url="$1"
  _wwr_out="$2"
  _wwr_sha="${3:-}"
  _wwr_label="${4:-$1}"
  warren_download_retry "$_wwr_url" "$_wwr_out" "$_wwr_sha" "$_wwr_label" ||
    fail "Не удалось загрузить $_wwr_label после 3 попыток: $_wwr_url"
}

# Service scripts shipped in payload/ (router services, VPS helpers). They run as
# separate processes and must not depend on lib/*.sh.
# Lookup: $WARREN_PAYLOAD_DIR (tests/dev), then fetch_payload from warren.sh.
warren_payload_source() {
  _wp_name="$1"
  if [ -n "${WARREN_PAYLOAD_DIR:-}" ] && [ -r "$WARREN_PAYLOAD_DIR/$_wp_name" ]; then
    printf "%s" "$WARREN_PAYLOAD_DIR/$_wp_name"
    return 0
  fi
  if command -v fetch_payload >/dev/null 2>&1; then
    fetch_payload "$_wp_name"
    return
  fi
  [ -r "/usr/lib/warren/payload/$_wp_name" ] || return 1
  printf "%s" "/usr/lib/warren/payload/$_wp_name"
}

warren_install_payload() {
  _wp_name="$1"
  _wp_target="$2"
  _wp_src="$(warren_payload_source "$_wp_name")" && [ -r "$_wp_src" ] ||
    fail "Не найден payload Warren: $_wp_name"
  mkdir -p "$(dirname "$_wp_target")" || fail "Не удалось создать каталог для $_wp_target"
  _wp_tmp="${_wp_target}.tmp.$$"
  cp "$_wp_src" "$_wp_tmp" && mv "$_wp_tmp" "$_wp_target" || {
    rm -f "$_wp_tmp" 2>/dev/null || true
    fail "Не удалось установить payload $_wp_name в $_wp_target"
  }
}

download_file() {
  url="$1"
  out="$2"
  expected_sha="$3"
  label="$4"

  warren_wget_retry "$url" "$out" "${expected_sha:-}" "$label"

  if [ -z "$expected_sha" ]; then
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
  warren_openwrt_family "$rel" >/dev/null 2>&1
}

pkg_invalidate_installed_cache() {
  WARREN_PKG_INSTALLED_CACHE=""
}

pkg_is_installed() {
  pkg="$1"

  if pkg_manager_is_opkg; then
    if [ -z "${WARREN_PKG_INSTALLED_CACHE:-}" ]; then
      WARREN_PKG_INSTALLED_CACHE="$(opkg list-installed 2>/dev/null)"
    fi
    printf "%s\n" "$WARREN_PKG_INSTALLED_CACHE" | grep -q "^${pkg} "
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
    _rc="$?"
    pkg_invalidate_installed_cache
    return "$_rc"
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
    _rc="$?"
    pkg_invalidate_installed_cache
    return "$_rc"
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
