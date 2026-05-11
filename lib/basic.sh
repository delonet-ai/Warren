check_openwrt() {
  rel="$(openwrt_release_version)"
  [ -n "$rel" ] || fail "Не удалось определить версию OpenWrt."
  openwrt_release_supported || fail "Нужен OpenWrt 24.10.x или 25.12.x (сейчас: ${rel:-unknown})."

  pm="$(pkg_manager 2>/dev/null || true)"
  [ -n "$pm" ] || fail "Не удалось определить пакетный менеджер OpenWrt."
  done_ "OpenWrt версия: $rel, пакетный менеджер: $pm"
}

check_inet() {
  ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || fail "Нет базовой связности (ping 1.1.1.1)."
  done_ "Базовая связность OK"
}

sync_time() {
  warren_set_timezone_moscow || warn "Не удалось применить timezone Europe/Moscow через UCI."
  warren_restart_ntp

  if warren_time_sane; then
    :
  else
    warren_ntp_sync_once || true
  fi

  if ! warren_time_sane && [ -n "${BROWSER_EPOCH:-}" ]; then
    info "Пробую выставить время от браузера LuCI..."
    if warren_set_time_from_epoch "$BROWSER_EPOCH"; then
      warren_restart_ntp
      sleep 2
    else
      warn "Не удалось принять время из браузера LuCI."
    fi
  fi

  warren_ntp_sync_once || true
  warren_require_sane_time "Podkop и HTTPS-проверок"
  wget -q --spider https://downloads.openwrt.org/ || fail "После синхронизации времени всё ещё нет DNS/TLS (wget https://downloads.openwrt.org)."
  done_ "Время и HTTPS проверены"
}

install_full_pkg_list() {
  common_pkgs="parted losetup resize2fs blkid e2fsprogs block-mount fstrim tune2fs ca-bundle ca-certificates curl tcpdump kmod-nft-tproxy"
  essential_pkgs="$common_pkgs ip-full"

  if pkg_manager_is_apk; then
    optional_pkgs="nano-full wget-ssl"
  else
    optional_pkgs="nano-full wget-ssl"
  fi

  # shellcheck disable=SC2086
  pkg_ensure_installed $essential_pkgs

  optional_missing=""
  for pkg in $optional_pkgs; do
    pkg_is_installed "$pkg" || optional_missing="$optional_missing $pkg"
  done

  if [ -n "$optional_missing" ]; then
    pkg_update_indexes || true
    # shellcheck disable=SC2086
    if ! pkg_install_packages $optional_missing; then
      warn "Не все необязательные пакеты удалось поставить:$optional_missing"
    fi
  fi

  done_ "Установлен полный список пакетов"
}

overlay_report_and_prepare_expand() {
  set -- $(df -k /overlay 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
  total_kb="${1:-0}"
  used_kb="${2:-0}"
  avail_kb="${3:-0}"

  total_mb=$((total_kb/1024))
  used_mb=$((used_kb/1024))
  avail_mb=$((avail_kb/1024))

  say ""
  say "Overlay (место под пакеты): всего ${total_mb}MB, занято ${used_mb}MB, свободно ${avail_mb}MB"
  say "Expand-root выполняется автоматически, без дополнительных вопросов."
  say ""
  return 0
}

check_space_overlay() {
  free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$free_kb" ] || fail "Не вижу /overlay"
  done_ "Свободно /overlay: $((free_kb/1024)) MB"
}

basic_stage_note() {
  case "$1" in
    preflight) info "Basic: preflight (OpenWrt / интернет / время)" ;;
    packages) info "Basic: установка базовых пакетов через $(pkg_manager)" ;;
    overlay) info "Basic: проверка overlay и подготовка expand-root" ;;
    reboot) info "Basic: автоматический expand-root и ребут" ;;
    post_reboot) info "Basic: post-reboot проверка пакетов и места" ;;
  esac
}
