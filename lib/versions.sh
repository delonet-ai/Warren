WARREN_SUPPORTED_OPENWRT_FAMILIES="${WARREN_SUPPORTED_OPENWRT_FAMILIES:-24 25}"
WARREN_OPENWRT_PINNED_RELEASE="${WARREN_OPENWRT_PINNED_RELEASE:-25.12.5}"
WARREN_OPENWRT_R5S_SYSUPGRADE_GZ_SHA256="${WARREN_OPENWRT_R5S_SYSUPGRADE_GZ_SHA256:-7d02fdc12d1339ce5fece5845c3c45c78f6bb8c92f8318fd993a5198bcfe3f9f}"
WARREN_PODKOP_RELEASE_TAG="${WARREN_PODKOP_RELEASE_TAG:-0.7.21}"
WARREN_PODKOP_INSTALL_SHA256="${WARREN_PODKOP_INSTALL_SHA256:-292da42b060f2eea935de80e3dd9ace4bb980a9559afb1af175f4468b7c9263f}"
WARREN_3XUI_PINNED_RELEASE_TAG="${WARREN_3XUI_PINNED_RELEASE_TAG:-v3.5.0}"
WARREN_3XUI_INSTALL_SHA256="${WARREN_3XUI_INSTALL_SHA256:-f2f8caa11778d811a037fe84b20ebf5e2547fd665afe6fe16d69f1cd9f3fe88f}"
WARREN_REMOTE_ADMIN_PROTOCOL_VERSION="${WARREN_REMOTE_ADMIN_PROTOCOL_VERSION:-1}"
WARREN_LUCI_BUNDLE_VERSION="${WARREN_LUCI_BUNDLE_VERSION:-${WARREN_VERSION:-0.6.2}}"

WARREN_AWG_PACKAGE_SOURCE="${WARREN_AWG_PACKAGE_SOURCE:-slava-shchipunov}"
WARREN_AWG_REPO_BASE_SLAVA="${WARREN_AWG_REPO_BASE_SLAVA:-https://github.com/Slava-Shchipunov/awg-openwrt/releases/download}"
WARREN_AWG_PACKAGES_V2="${WARREN_AWG_PACKAGES_V2:-kmod-amneziawg amneziawg-tools luci-proto-amneziawg}"
WARREN_AWG_PACKAGES_V1="${WARREN_AWG_PACKAGES_V1:-kmod-amneziawg amneziawg-tools luci-app-amneziawg}"
WARREN_AWG_FALLBACK_PATCH_SCAN_AHEAD="${WARREN_AWG_FALLBACK_PATCH_SCAN_AHEAD:-3}"

warren_openwrt_family() {
  rel="${1:-$(openwrt_release_version 2>/dev/null || true)}"
  case "$rel" in
    24.*) printf "%s" "24"; return 0 ;;
    25.*) printf "%s" "25"; return 0 ;;
  esac
  major="${rel%%.*}"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$major" -ge 26 ]; then
    printf "%s" "unknown/graceful"
    return 0
  fi
  return 1
}

warren_openwrt_family_supported() {
  case "$(warren_openwrt_family "$1" 2>/dev/null || true)" in
    24|25) return 0 ;;
    *) return 1 ;;
  esac
}

warren_openwrt_release_graceful() {
  [ "$(warren_openwrt_family "$1" 2>/dev/null || true)" = "unknown/graceful" ]
}

warren_expected_pkg_manager_for_release() {
  family="$(warren_openwrt_family "$1" 2>/dev/null || true)"
  case "$family" in
    24) printf "%s" "opkg"; return 0 ;;
    25) printf "%s" "apk"; return 0 ;;
    unknown/graceful) detect_pkg_manager; return $? ;;
  esac
  return 1
}

warren_check_pkg_manager_matches_openwrt() {
  rel="${1:-$(openwrt_release_version 2>/dev/null || true)}"
  pm="${2:-$(pkg_manager 2>/dev/null || true)}"
  if warren_openwrt_release_graceful "$rel"; then
    expected="$pm"
  else
    expected="$(warren_expected_pkg_manager_for_release "$rel" 2>/dev/null || true)"
  fi

  [ -n "$expected" ] || fail "Нужен OpenWrt 24.x, 25.x или будущий 26.x+ в graceful mode (сейчас: ${rel:-unknown})."
  [ -n "$pm" ] || fail "Не удалось определить пакетный менеджер OpenWrt."
  if warren_openwrt_release_graceful "$rel"; then
    warn "OpenWrt ${rel} ещё не проверен Warren; продолжаю в graceful mode с package manager ${pm}."
    if [ "${WARREN_ALLOW_UNKNOWN_OPENWRT:-0}" != "1" ] &&
       [ "${WARREN_LUCI_REQUEST:-0}" != "1" ]; then
      ask "Продолжить на непроверенном OpenWrt ${rel}? (y/n)" WARREN_UNKNOWN_OPENWRT_CONFIRM "n"
      case "$WARREN_UNKNOWN_OPENWRT_CONFIRM" in
        y|Y) ;;
        *) fail "Запуск на непроверенном OpenWrt отменён." ;;
      esac
    fi
    WARREN_OPENWRT_GRACEFUL=1
    return 0
  fi
  [ "$pm" = "$expected" ] || fail "OpenWrt ${rel} должен использовать ${expected}, сейчас найден ${pm}."
}

warren_awg_release_family() {
  printf "%s" "$1" | cut -d. -f1,2
}

warren_podkop_install_url_default() {
  printf "https://raw.githubusercontent.com/itdoginfo/podkop/refs/tags/%s/install.sh" "$WARREN_PODKOP_RELEASE_TAG"
}

warren_versions_apply_defaults() {
  [ -n "${PODKOP_INSTALL_URL:-}" ] || PODKOP_INSTALL_URL="$(warren_podkop_install_url_default)"
  [ -n "${PODKOP_INSTALL_SHA256:-}" ] || PODKOP_INSTALL_SHA256="$WARREN_PODKOP_INSTALL_SHA256"
  [ -n "${WARREN_3XUI_RELEASE_TAG:-}" ] || WARREN_3XUI_RELEASE_TAG="$WARREN_3XUI_PINNED_RELEASE_TAG"
}

warren_awg_protocol_version_for_release() {
  rel="$1"
  major="$(printf "%s" "$rel" | cut -d. -f1)"
  minor="$(printf "%s" "$rel" | cut -d. -f2)"
  patch="$(printf "%s" "$rel" | cut -d. -f3)"
  [ -n "$patch" ] || patch=0

  if [ "$major" -gt 24 ] || \
     { [ "$major" -eq 24 ] && [ "$minor" -gt 10 ]; } || \
     { [ "$major" -eq 24 ] && [ "$minor" -eq 10 ] && [ "$patch" -ge 3 ]; } || \
     { [ "$major" -eq 23 ] && [ "$minor" -eq 5 ] && [ "$patch" -ge 6 ]; }
  then
    printf "%s" "2.0"
  else
    printf "%s" "1.0"
  fi
}

warren_awg_packages_for_protocol() {
  case "$1" in
    1.0) printf "%s" "$WARREN_AWG_PACKAGES_V1" ;;
    *) printf "%s" "$WARREN_AWG_PACKAGES_V2" ;;
  esac
}

warren_awg_release_base_url() {
  tag="$1"
  case "${WARREN_AWG_PACKAGE_SOURCE:-slava-shchipunov}" in
    slava-shchipunov) printf "%s/%s" "$WARREN_AWG_REPO_BASE_SLAVA" "$tag" ;;
    *) return 1 ;;
  esac
}

warren_awg_package_extensions_for_pm() {
  case "$1" in
    apk) printf "%s" "apk ipk" ;;
    *) printf "%s" "ipk apk" ;;
  esac
}

warren_awg_pkg_postfix_for() {
  printf "_v%s_%s_%s_%s" "$1" "$2" "$3" "$4"
}

warren_awg_patch_number() {
  printf "%s" "$1" | cut -d. -f3
}

warren_awg_candidate_releases() {
  rel="$1"
  awg_family="$(warren_awg_release_family "$rel")"
  patch="$(warren_awg_patch_number "$rel")"
  scan_ahead="${WARREN_AWG_FALLBACK_PATCH_SCAN_AHEAD:-3}"

  case "$patch" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$awg_family" ] || return 1
  warren_openwrt_family "$rel" >/dev/null 2>&1 || return 1

  i="$patch"
  while [ "$i" -ge 0 ]; do
    printf "%s.%s\n" "$awg_family" "$i"
    i=$((i - 1))
  done

  i=$((patch + 1))
  max=$((patch + scan_ahead))
  while [ "$i" -le "$max" ]; do
    printf "%s.%s\n" "$awg_family" "$i"
    i=$((i + 1))
  done
}

warren_awg_probe_url() {
  url="$1"
  # Existence check only: never download the package. Retry with backoff: right
  # after a Podkop restart DNS/routing can be down for a few seconds, and a
  # transient failure must not push the resolver onto a wrong-kernel fallback.
  attempt=1
  while [ "$attempt" -le 3 ]; do
    [ "$attempt" -eq 1 ] || sleep "$(warren_retry_delay "$attempt")"
    warren_wget -q --spider "$url" 2>/dev/null && return 0
    attempt=$((attempt + 1))
  done
  return 1
}

warren_awg_resolve_package_url() {
  release="$1"
  pkg="$2"
  pm="$3"
  arch="$4"
  target_main="$5"
  subtarget="$6"

  tag="v${release}"
  base_url="$(warren_awg_release_base_url "$tag")" || return 1
  postfix="$(warren_awg_pkg_postfix_for "$release" "$arch" "$target_main" "$subtarget")"

  for ext in $(warren_awg_package_extensions_for_pm "$pm"); do
    pkg_file="${pkg}${postfix}.${ext}"
    pkg_url="${base_url}/${pkg_file}"
    if warren_awg_probe_url "$pkg_url"; then
      printf "%s|%s|%s\n" "$pkg_url" "$pkg_file" "$ext"
      return 0
    fi
  done

  return 1
}

warren_awg_release_has_packages() {
  release="$1"
  pm="$2"
  arch="$3"
  target_main="$4"
  subtarget="$5"
  protocol="$(warren_awg_protocol_version_for_release "$release")"

  for pkg in $(warren_awg_packages_for_protocol "$protocol"); do
    warren_awg_resolve_package_url "$release" "$pkg" "$pm" "$arch" "$target_main" "$subtarget" >/dev/null || return 1
  done

  return 0
}

# Kernel version an OpenWrt release ships for a target, e.g. "6.12.94".
warren_openwrt_release_kernel() {
  release="$1"
  target_main="$2"
  subtarget="$3"
  profiles_tmp="${AWG_STAGE_DIR:-/tmp/amneziawg}/profiles.$$"
  mkdir -p "$(dirname "$profiles_tmp")" 2>/dev/null || return 1
  warren_wget -qO "$profiles_tmp" \
    "${WARREN_OPENWRT_DOWNLOADS_URL:-https://downloads.openwrt.org}/releases/${release}/targets/${target_main}/${subtarget}/profiles.json" \
    2>/dev/null || { rm -f "$profiles_tmp"; return 1; }
  kernel="$(tr -d '\n' < "$profiles_tmp" | sed -n 's/.*"linux_kernel"[^}]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  rm -f "$profiles_tmp" 2>/dev/null || true
  [ -n "$kernel" ] || return 1
  printf "%s" "$kernel"
}

# kmod-amneziawg only loads on the exact kernel it was built for, so a fallback
# release is usable only when it ships the running kernel.
warren_awg_fallback_kernel_matches() {
  candidate="$1"
  target_main="$2"
  subtarget="$3"
  running_kernel="${WARREN_RUNNING_KERNEL:-$(uname -r 2>/dev/null)}"
  candidate_kernel="$(warren_openwrt_release_kernel "$candidate" "$target_main" "$subtarget")" || return 1
  [ "$candidate_kernel" = "$running_kernel" ]
}

warren_awg_select_release() {
  exact_release="$1"
  pm="$2"
  arch="$3"
  target_main="$4"
  subtarget="$5"

  if warren_awg_release_has_packages "$exact_release" "$pm" "$arch" "$target_main" "$subtarget"; then
    printf "%s|exact\n" "$exact_release"
    return 0
  fi

  warren_awg_candidate_releases "$exact_release" | while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$exact_release" ] || continue
    if warren_awg_release_has_packages "$candidate" "$pm" "$arch" "$target_main" "$subtarget" &&
      warren_awg_fallback_kernel_matches "$candidate" "$target_main" "$subtarget"; then
      printf "%s|fallback\n" "$candidate"
      exit 0
    fi
  done
}

warren_version_policy_summary() {
  cat <<EOF
OpenWrt families: ${WARREN_SUPPORTED_OPENWRT_FAMILIES}
Tested OpenWrt release: ${WARREN_OPENWRT_PINNED_RELEASE}
Podkop installer tag/SHA256: ${WARREN_PODKOP_RELEASE_TAG} / ${WARREN_PODKOP_INSTALL_SHA256}
3x-ui tag/SHA256: ${WARREN_3XUI_PINNED_RELEASE_TAG} / ${WARREN_3XUI_INSTALL_SHA256}
AWG source: ${WARREN_AWG_PACKAGE_SOURCE}
Remote Admin protocol: ${WARREN_REMOTE_ADMIN_PROTOCOL_VERSION}
Warren/LuCI bundle: ${WARREN_LUCI_BUNDLE_VERSION}
EOF
}
