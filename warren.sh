#!/bin/sh
# Warren main entrypoint: packages -> expand-root (reboot) -> podkop -> private access
# Designed for OpenWrt 24.10.x / 25.12.x on NanoPi R5S/R5C
# Usage (GitHub): wget -O /tmp/warren.sh "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" && sh /tmp/warren.sh

set -e

TTY="${TTY:-/dev/tty}"
EXPAND_ROOT_URL="${EXPAND_ROOT_URL:-https://openwrt.org/_export/code/docs/guide-user/advanced/expand_root?codeblock=0}"
PODKOP_INSTALL_URL="${PODKOP_INSTALL_URL:-}"
EXPAND_ROOT_SHA256="${EXPAND_ROOT_SHA256:-}"
PODKOP_INSTALL_SHA256="${PODKOP_INSTALL_SHA256:-}"
WARREN_RAW_BASE_URL="${WARREN_RAW_BASE_URL:-${BOOTSTRAP_RAW_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main}}"
WARREN_LIB_BASE_URL="${WARREN_LIB_BASE_URL:-${BOOTSTRAP_LIB_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main/lib}}"
WARREN_ASSET_BASE_URL="${WARREN_ASSET_BASE_URL:-${BOOTSTRAP_ASSET_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main/assets}}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo ".")"
WARREN_DEV_DIR_DEFAULT="${SCRIPT_DIR}/.warren-dev"
WARREN_CLI_ARG1="${1:-}"
WARREN_CLI_ARG2="${2:-}"

WARREN_LIB_LIST="common.sh versions.sh ui.sh state.sh basic.sh podkop.sh watchdog.sh amneziawg.sh vps.sh amnezia.sh qos.sh remote_admin.sh usb_modem.sh tg_bot.sh diagnostics.sh sni_checker.sh luci.sh"

migrate_legacy_file_if_missing() {
  legacy_path="$1"
  target_path="$2"
  [ -f "$legacy_path" ] || return 0
  [ -e "$target_path" ] && return 0
  mkdir -p "$(dirname "$target_path")" 2>/dev/null || true
  mv "$legacy_path" "$target_path" 2>/dev/null || cp "$legacy_path" "$target_path" 2>/dev/null || true
}

migrate_legacy_dir_if_missing() {
  legacy_path="$1"
  target_path="$2"
  [ -d "$legacy_path" ] || return 0
  [ -e "$target_path" ] && return 0
  mkdir -p "$(dirname "$target_path")" 2>/dev/null || true
  mv "$legacy_path" "$target_path" 2>/dev/null || cp -R "$legacy_path" "$target_path" 2>/dev/null || true
}

if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && [ -w /etc ] && [ -d /root ]; then
  WARREN_LEGACY_BASE_DIR="${WARREN_LEGACY_BASE_DIR:-/etc}"
  WARREN_LEGACY_LOG_DIR="${WARREN_LEGACY_LOG_DIR:-/root}"
  WARREN_BASE_DIR="${WARREN_BASE_DIR:-/etc/warren}"
  WARREN_LOG_DIR="${WARREN_LOG_DIR:-/root/warren}"
  WARREN_APP_DIR="${WARREN_APP_DIR:-${WARREN_LOG_DIR}/app}"
  STATE="${STATE:-${WARREN_BASE_DIR}/warren.state}"
  CONF="${CONF:-${WARREN_BASE_DIR}/warren.conf}"
  LOG="${LOG:-${WARREN_LOG_DIR}/warren.log}"
  LIB_CACHE_DIR="${LIB_CACHE_DIR:-/tmp/warren-lib}"
  ASSET_CACHE_DIR="${ASSET_CACHE_DIR:-/tmp/warren-assets}"
  AUTO_STATE_JSON="${AUTO_STATE_JSON:-/tmp/warren-runtime.json}"
  AUTO_STATE_STORE="${AUTO_STATE_STORE:-/tmp/warren-runtime.tsv}"
  mkdir -p "$WARREN_BASE_DIR" "$WARREN_LOG_DIR" "$WARREN_APP_DIR" || {
    printf "%s\n" "Не удалось создать каталоги Warren: $WARREN_BASE_DIR $WARREN_LOG_DIR $WARREN_APP_DIR" >&2
    exit 1
  }
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren.state" "$STATE"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren.conf" "$CONF"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren-tg-bot.conf" "${WARREN_BASE_DIR}/warren-tg-bot.conf"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_BASE_DIR}/warren-vless-endpoints" "${WARREN_BASE_DIR}/warren-vless-endpoints"
  migrate_legacy_dir_if_missing "${WARREN_LEGACY_BASE_DIR}/vps" "${WARREN_BASE_DIR}/vps"
  migrate_legacy_file_if_missing "${WARREN_LEGACY_LOG_DIR}/warren.log" "$LOG"
  migrate_legacy_dir_if_missing "${WARREN_LEGACY_LOG_DIR}/warren-diagnostics" "${WARREN_LOG_DIR}/warren-diagnostics"
else
  WARREN_DEV_DIR="${WARREN_DEV_DIR:-$WARREN_DEV_DIR_DEFAULT}"
  mkdir -p "$WARREN_DEV_DIR" || {
    printf "%s\n" "Не удалось создать каталог для локального режима: $WARREN_DEV_DIR" >&2
    exit 1
  }
  STATE="${STATE:-${WARREN_DEV_DIR}/warren.state}"
  CONF="${CONF:-${WARREN_DEV_DIR}/warren.conf}"
  LOG="${LOG:-${WARREN_DEV_DIR}/warren.log}"
  LIB_CACHE_DIR="${LIB_CACHE_DIR:-${WARREN_DEV_DIR}/lib-cache}"
  ASSET_CACHE_DIR="${ASSET_CACHE_DIR:-${WARREN_DEV_DIR}/asset-cache}"
  AUTO_STATE_JSON="${AUTO_STATE_JSON:-${WARREN_DEV_DIR}/warren-runtime.json}"
  AUTO_STATE_STORE="${AUTO_STATE_STORE:-${WARREN_DEV_DIR}/warren-runtime.tsv}"
fi

warren_die() {
  printf "%s\n" "$*" >&2
  exit 1
}

warren_retry_delay() {
  case "$1" in
    2) printf "%s" "5" ;;
    3) printf "%s" "15" ;;
    *) printf "%s" "0" ;;
  esac
}

warren_sha256_file() {
  command -v sha256sum >/dev/null 2>&1 || return 1
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

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
    if wget -qO "$_wdr_out" "$_wdr_url" 2>/dev/null; then
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

warren_version_manifest_sha() {
  _wvms_version="$1"
  [ -r "$_wvms_version" ] || return 1
  sed -n 's/^SUMS_SHA256=//p' "$_wvms_version" | sed -n '1p' | tr -d '\r'
}

warren_persistent_lib_dir() {
  printf "%s" "/usr/lib/warren/lib"
}

warren_persistent_asset_dir() {
  printf "%s" "/usr/lib/warren/assets"
}

warren_persistent_version_path() {
  printf "%s" "/usr/lib/warren/VERSION"
}

warren_persistent_manifest_path() {
  printf "%s" "/usr/lib/warren/SUMS.txt"
}

warren_launcher_path() {
  printf "%s" "/usr/bin/warren"
}

warren_persistent_script_path() {
  printf "%s/warren.sh" "${WARREN_APP_DIR:-/root/warren/app}"
}

warren_local_version_file() {
  printf "%s/VERSION" "$SCRIPT_DIR"
}

warren_read_version_from_file() {
  version_file="$1"
  [ -r "$version_file" ] || return 1
  sed -n '1p' "$version_file" | tr -d '\r'
}

warren_local_version() {
  version="$(warren_read_version_from_file "$(warren_local_version_file)")" || true
  [ -n "$version" ] || version="$(warren_read_version_from_file "$(warren_persistent_version_path)")" || true
  [ -n "$version" ] || version="unknown"
  printf "%s" "$version"
}

warren_install_bootstrap_file() {
  src_path="$1"
  dst_path="$2"
  src_url="$3"
  force_remote="${4:-0}"
  expected_sha="${5:-}"
  payload_label="${6:-$dst_path}"

  mkdir -p "$(dirname "$dst_path")" || warren_die "Не удалось создать каталог для $dst_path"
  tmp_path="${dst_path}.tmp.$$"

  if [ -r "$src_path" ]; then
    cp "$src_path" "$tmp_path" || warren_die "Не удалось скопировать $src_path"
    if ! warren_verify_file_hash "$tmp_path" "$expected_sha" "$payload_label"; then
      rm -f "$tmp_path" 2>/dev/null || true
      warren_die "Проверка целостности не пройдена: $payload_label"
    fi
  elif [ "$force_remote" = "1" ] && [ -n "$src_url" ]; then
    warren_download_retry "$src_url" "$tmp_path" "$expected_sha" "$payload_label" ||
      warren_die "Не удалось скачать и проверить после 3 попыток: $payload_label"
  elif [ -r "$dst_path" ]; then
    return 0
  elif [ -n "$src_url" ]; then
    warren_download_retry "$src_url" "$tmp_path" "$expected_sha" "$payload_label" ||
      warren_die "Не удалось скачать и проверить после 3 попыток: $payload_label"
  else
    warren_die "Не найден локальный файл и URL для $dst_path"
  fi

  mv "$tmp_path" "$dst_path" || warren_die "Не удалось записать $dst_path"
}

warren_prepare_bootstrap_manifest() {
  force_remote="${1:-0}"
  WARREN_ACTIVE_VERSION_FILE=""
  WARREN_ACTIVE_MANIFEST=""

  local_version="$SCRIPT_DIR/VERSION"
  local_manifest="$SCRIPT_DIR/SUMS.txt"
  persistent_version="$(warren_persistent_version_path)"
  persistent_manifest="$(warren_persistent_manifest_path)"

  if [ "${WARREN_SKIP_HASH_CHECK:-0}" = "1" ]; then
    if [ -r "$local_version" ]; then
      WARREN_ACTIVE_VERSION_FILE="$local_version"
    elif [ -r "$persistent_version" ]; then
      WARREN_ACTIVE_VERSION_FILE="$persistent_version"
    fi
    [ -r "$local_manifest" ] && WARREN_ACTIVE_MANIFEST="$local_manifest"
    [ -n "$WARREN_ACTIVE_MANIFEST" ] ||
      [ ! -r "$persistent_manifest" ] ||
      WARREN_ACTIVE_MANIFEST="$persistent_manifest"
    return 0
  fi

  if [ "$force_remote" != "1" ] && [ -r "$local_version" ] && [ -r "$local_manifest" ]; then
    WARREN_ACTIVE_VERSION_FILE="$local_version"
    WARREN_ACTIVE_MANIFEST="$local_manifest"
  elif [ "$force_remote" != "1" ] && [ -r "$persistent_version" ] && [ -r "$persistent_manifest" ]; then
    WARREN_ACTIVE_VERSION_FILE="$persistent_version"
    WARREN_ACTIVE_MANIFEST="$persistent_manifest"
  else
    metadata_dir="${LIB_CACHE_DIR}/metadata.$$"
    mkdir -p "$metadata_dir" || warren_die "Не удалось создать каталог metadata"
    WARREN_ACTIVE_VERSION_FILE="$metadata_dir/VERSION"
    WARREN_ACTIVE_MANIFEST="$metadata_dir/SUMS.txt"
    warren_download_retry \
      "$WARREN_RAW_BASE_URL/VERSION" \
      "$WARREN_ACTIVE_VERSION_FILE" \
      "" \
      "Warren VERSION" ||
      warren_die "Не удалось скачать Warren VERSION после 3 попыток"
    expected_manifest_sha="$(warren_version_manifest_sha "$WARREN_ACTIVE_VERSION_FILE")" || true
    [ -n "$expected_manifest_sha" ] ||
      warren_die "VERSION не содержит SUMS_SHA256; используй WARREN_SKIP_HASH_CHECK=1 только для dev"
    warren_download_retry \
      "$WARREN_RAW_BASE_URL/SUMS.txt" \
      "$WARREN_ACTIVE_MANIFEST" \
      "$expected_manifest_sha" \
      "Warren SUMS.txt" ||
      warren_die "Не удалось скачать или проверить Warren SUMS.txt"
  fi

  expected_manifest_sha="$(warren_version_manifest_sha "$WARREN_ACTIVE_VERSION_FILE")" || true
  [ -n "$expected_manifest_sha" ] ||
    warren_die "VERSION не содержит SUMS_SHA256; используй WARREN_SKIP_HASH_CHECK=1 только для dev"
  warren_verify_file_hash "$WARREN_ACTIVE_MANIFEST" "$expected_manifest_sha" "Warren SUMS.txt" ||
    warren_die "Проверка целостности Warren SUMS.txt не пройдена"
}

warren_payload_sha() {
  payload_path="$1"
  [ "${WARREN_SKIP_HASH_CHECK:-0}" = "1" ] && return 0
  payload_sha="$(warren_manifest_sha "$WARREN_ACTIVE_MANIFEST" "$payload_path")" || true
  [ -n "$payload_sha" ] ||
    warren_die "В SUMS.txt нет SHA256 для $payload_path"
  printf "%s" "$payload_sha"
}

warren_bootstrap_install_persistent_app() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  [ -n "${WARREN_APP_DIR:-}" ] || return 0

  app_script="$(warren_persistent_script_path)"
  launcher_path="$(warren_launcher_path)"
  lib_dir="$(warren_persistent_lib_dir)"
  asset_dir="$(warren_persistent_asset_dir)"
  version_path="$(warren_persistent_version_path)"
  force_remote="${1:-${WARREN_BOOTSTRAP_FORCE_REMOTE:-0}}"

  mkdir -p "$WARREN_APP_DIR" "$lib_dir" "$asset_dir" || warren_die "Не удалось подготовить постоянный каталог Warren"
  warren_prepare_bootstrap_manifest "$force_remote"

  if [ "$force_remote" = "1" ]; then
    warren_install_bootstrap_file "" "$app_script" "$WARREN_RAW_BASE_URL/warren.sh" "$force_remote" \
      "$(warren_payload_sha warren.sh)" "warren.sh"
  else
    warren_install_bootstrap_file "$SCRIPT_DIR/warren.sh" "$app_script" "$WARREN_RAW_BASE_URL/warren.sh" "$force_remote" \
      "$(warren_payload_sha warren.sh)" "warren.sh"
  fi
  chmod 700 "$app_script" 2>/dev/null || true

  for lib in $WARREN_LIB_LIST; do
    if [ "$force_remote" = "1" ]; then
      warren_install_bootstrap_file "" "$lib_dir/$lib" "$WARREN_LIB_BASE_URL/$lib" "$force_remote" \
        "$(warren_payload_sha "lib/$lib")" "lib/$lib"
    else
      warren_install_bootstrap_file "$SCRIPT_DIR/lib/$lib" "$lib_dir/$lib" "$WARREN_LIB_BASE_URL/$lib" "$force_remote" \
        "$(warren_payload_sha "lib/$lib")" "lib/$lib"
    fi
    chmod 644 "$lib_dir/$lib" 2>/dev/null || true
  done

  for asset in sni-candidates.txt; do
    if [ "$force_remote" = "1" ]; then
      warren_install_bootstrap_file "" "$asset_dir/$asset" "$WARREN_ASSET_BASE_URL/$asset" "$force_remote" \
        "$(warren_payload_sha "assets/$asset")" "assets/$asset"
    else
      warren_install_bootstrap_file "$SCRIPT_DIR/assets/$asset" "$asset_dir/$asset" "$WARREN_ASSET_BASE_URL/$asset" "$force_remote" \
        "$(warren_payload_sha "assets/$asset")" "assets/$asset"
    fi
    chmod 644 "$asset_dir/$asset" 2>/dev/null || true
  done

  if [ -r "$WARREN_ACTIVE_VERSION_FILE" ]; then
    cp "$WARREN_ACTIVE_VERSION_FILE" "${version_path}.tmp.$$" ||
      warren_die "Не удалось подготовить VERSION"
    mv "${version_path}.tmp.$$" "$version_path" ||
      warren_die "Не удалось записать VERSION"
  fi
  chmod 644 "$version_path" 2>/dev/null || true
  manifest_path="$(warren_persistent_manifest_path)"
  if [ -r "$WARREN_ACTIVE_MANIFEST" ]; then
    cp "$WARREN_ACTIVE_MANIFEST" "${manifest_path}.tmp.$$" ||
      warren_die "Не удалось подготовить SUMS.txt"
    mv "${manifest_path}.tmp.$$" "$manifest_path" ||
      warren_die "Не удалось записать SUMS.txt"
  fi
  chmod 644 "$manifest_path" 2>/dev/null || true
  WARREN_ACTIVE_VERSION_FILE="$version_path"
  WARREN_ACTIVE_MANIFEST="$manifest_path"

  cat > "${launcher_path}.tmp.$$" <<EOF
#!/bin/sh
exec "$app_script" "\$@"
EOF
  mv "${launcher_path}.tmp.$$" "$launcher_path" || warren_die "Не удалось установить $launcher_path"
  chmod 755 "$launcher_path" 2>/dev/null || true

  WARREN_BOOTSTRAP_READY=1
}

warren_bootstrap_install_persistent_app "${WARREN_BOOTSTRAP_FORCE_REMOTE:-0}"

warren_should_check_updates() {
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 1
  [ "${WARREN_LUCI_REQUEST:-0}" != "1" ] || return 1
  [ -t 0 ] || [ -r "$TTY" ] || return 1
  [ "${WARREN_SKIP_UPDATE_CHECK:-0}" != "1" ] || return 1
  return 0
}

warren_remote_version() {
  remote_version_file="${LIB_CACHE_DIR}/remote-version.$$"
  mkdir -p "$LIB_CACHE_DIR" 2>/dev/null || return 1
  if warren_download_retry "$WARREN_RAW_BASE_URL/VERSION" "$remote_version_file" "" "Warren VERSION"; then
    sed -n '1p' "$remote_version_file" | tr -d '\r'
    rm -f "$remote_version_file" 2>/dev/null || true
    return 0
  fi
  rm -f "$remote_version_file" 2>/dev/null || true
  return 1
}

fetch_lib() {
  name="$1"
  local_path="$SCRIPT_DIR/lib/$name"
  system_path="/usr/lib/warren/lib/$name"
  use_local_libs="${WARREN_USE_LOCAL_LIBS:-}"

  case "$SCRIPT_DIR" in
    /tmp|/tmp/*)
      [ "$use_local_libs" = "1" ] || local_path=""
      ;;
  esac

  if [ -n "$local_path" ]; then
    if [ -r "$local_path" ]; then
      echo "$local_path"
      return 0
    fi
  fi

  if [ -r "$system_path" ]; then
    echo "$system_path"
    return 0
  fi

  mkdir -p "$LIB_CACHE_DIR" || warren_die "Не удалось создать каталог библиотек: $LIB_CACHE_DIR"
  cached_path="$LIB_CACHE_DIR/$name"
  lib_sha="$(warren_payload_sha "lib/$name")"
  warren_download_retry "$WARREN_LIB_BASE_URL/$name" "$cached_path" "$lib_sha" "lib/$name" ||
    warren_die "Не удалось скачать и проверить библиотеку после 3 попыток: $name"
  echo "$cached_path"
}

fetch_asset() {
  name="$1"
  local_path="$SCRIPT_DIR/assets/$name"
  system_path="/usr/lib/warren/assets/$name"
  use_local_libs="${WARREN_USE_LOCAL_LIBS:-}"

  case "$SCRIPT_DIR" in
    /tmp|/tmp/*)
      [ "$use_local_libs" = "1" ] || local_path=""
      ;;
  esac

  if [ -n "$local_path" ] && [ -r "$local_path" ]; then
    echo "$local_path"
    return 0
  fi

  if [ -r "$system_path" ]; then
    echo "$system_path"
    return 0
  fi

  mkdir -p "$ASSET_CACHE_DIR" || warren_die "Не удалось создать каталог ассетов: $ASSET_CACHE_DIR"
  cached_path="$ASSET_CACHE_DIR/$name"
  asset_sha="$(warren_payload_sha "assets/$name")"
  warren_download_retry "$WARREN_ASSET_BASE_URL/$name" "$cached_path" "$asset_sha" "assets/$name" ||
    warren_die "Не удалось скачать и проверить ассет после 3 попыток: $name"
  echo "$cached_path"
}

source_lib() {
  lib_path="$(fetch_lib "$1")"
  # shellcheck disable=SC1090
  . "$lib_path"
}

WARREN_VERSION="$(warren_local_version)"

source_lib common.sh
source_lib versions.sh
warren_versions_apply_defaults
source_lib ui.sh
source_lib state.sh
source_lib basic.sh
source_lib podkop.sh
source_lib watchdog.sh
source_lib amneziawg.sh
source_lib vps.sh
source_lib amnezia.sh
source_lib qos.sh
source_lib remote_admin.sh
source_lib usb_modem.sh
source_lib tg_bot.sh
source_lib diagnostics.sh
source_lib sni_checker.sh
source_lib luci.sh

warren_maybe_offer_update() {
  warren_should_check_updates || return 0

  remote_version="$(warren_remote_version)"
  [ -n "$remote_version" ] || return 0
  [ "$remote_version" != "$WARREN_VERSION" ] || return 0

  say ""
  say "${YELLOW}INFO${NC}  Доступна новая версия Warren."
  say "Текущая версия: $WARREN_VERSION"
  say "Версия в репозитории: $remote_version"
  ask "Обновить Warren сейчас и перезапустить? (y/n)" WARREN_UPDATE_CHOICE "y"

  case "$WARREN_UPDATE_CHOICE" in
    y|Y)
      info "Обновляю Warren из GitHub и перезапускаю через постоянный launcher..."
      warren_bootstrap_install_persistent_app 1
      exec "$(warren_launcher_path)" "$@"
      ;;
    n|N)
      warn "Продолжаю без обновления Warren."
      ;;
    *)
      fail "Введи y или n"
      ;;
  esac
}

luci_apply_form_overrides() {
  [ "${WARREN_LUCI_REQUEST:-0}" = "1" ] || return 0

  case "${MODE:-}" in
    auto|podkop_setup|podkop_backup|vps)
      if [ "${WARREN_LUCI_FORM:-0}" = "1" ] || [ -n "${LUCI_AUTO_VPS_SOURCE:-}${LUCI_SELECTED_VPS_REPORT:-}${LUCI_VLESS:-}${LUCI_VPS_HOST:-}${LUCI_VPS_ROOT_PASSWORD:-}" ]; then
        AUTO_VPS_SOURCE="${LUCI_AUTO_VPS_SOURCE:-}"
        SELECTED_VPS_REPORT="${LUCI_SELECTED_VPS_REPORT:-}"
        VLESS="${LUCI_VLESS:-}"
        VPS_HOST="${LUCI_VPS_HOST:-}"
        VPS_SSH_PORT="${LUCI_VPS_SSH_PORT:-22}"
        VPS_ROOT_PASSWORD="${LUCI_VPS_ROOT_PASSWORD:-}"
      fi
      ;;
    remote_admin|remote_admin_config)
      REMOTE_ADMIN_ROUTER_ID="${LUCI_REMOTE_ADMIN_ROUTER_ID:-}"
      REMOTE_ADMIN_ROUTER_NAME="${LUCI_REMOTE_ADMIN_ROUTER_NAME:-}"
      REMOTE_ADMIN_ENDPOINTS="${LUCI_REMOTE_ADMIN_ENDPOINTS:-}"
      REMOTE_ADMIN_VPS_USER="${LUCI_REMOTE_ADMIN_VPS_USER:-}"
      REMOTE_ADMIN_POLL_INTERVAL="${LUCI_REMOTE_ADMIN_POLL_INTERVAL:-}"
      REMOTE_ADMIN_REQUEST_TTL="${LUCI_REMOTE_ADMIN_REQUEST_TTL:-}"
      REMOTE_ADMIN_MAC_LUCI_PORT="${LUCI_REMOTE_ADMIN_MAC_LUCI_PORT:-}"
      REMOTE_ADMIN_LOCAL_SSH_PORT="${LUCI_REMOTE_ADMIN_LOCAL_SSH_PORT:-}"
      REMOTE_ADMIN_LOCAL_LUCI_PORT="${LUCI_REMOTE_ADMIN_LOCAL_LUCI_PORT:-}"
      REMOTE_ADMIN_ROUTER_KEY_PATH="${LUCI_REMOTE_ADMIN_ROUTER_KEY_PATH:-}"
      REMOTE_ADMIN_ENABLED="${LUCI_REMOTE_ADMIN_ENABLED:-1}"
      ;;
    sni_apply)
      SELECTED_VPS_REPORT="${LUCI_SELECTED_VPS_REPORT:-}"
      SNI_APPLY_SOURCE="${LUCI_SNI_APPLY_SOURCE:-best}"
      SNI_NEW="${LUCI_SNI_NEW:-}"
      SNI_REPORT_PATH="${LUCI_SNI_REPORT_PATH:-}"
      ;;
  esac

  if [ -n "${LUCI_BROWSER_EPOCH:-}" ]; then
    BROWSER_EPOCH="${LUCI_BROWSER_EPOCH:-}"
  fi

  case "${MODE:-}" in
    tg_bot)
      TG_BOT_TOKEN="${LUCI_TG_BOT_TOKEN:-}"
      TG_BOT_CHAT_ID="${LUCI_TG_BOT_CHAT_ID:-}"
      ;;
  esac

  case "${MODE:-}" in
    amnezia_client_create|amnezia_client_delete)
      AMZ_CLIENT_NAME="${LUCI_AMZ_CLIENT_NAME:-}"
      ;;
    qos_private)
      QOS_CLIENT_NAME="${LUCI_QOS_CLIENT_NAME:-}"
      QOS_PROFILE="${LUCI_QOS_PROFILE:-}"
      ;;
  esac

  case "${MODE:-}" in
    auto|podkop_setup)
      LIST_RU="1"
      LIST_CF="1"
      LIST_META="1"
      LIST_GOOGLE_AI="1"
      ;;
  esac

  save_conf
  if [ "${MODE:-}" = "auto" ]; then
    capture_runtime_inputs
  fi
}

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
  sh /etc/uci-defaults/70-rootpt-resize || true
  set_state 60
  done_ "Запущен expand-root. Сейчас будет ребут. После загрузки запусти скрипт снова."
  reboot
  fail "Команда reboot не выполнилась"
}

mode_is_podkop() {
  [ "$MODE" = "podkop_setup" ] || [ "$MODE" = "auto" ]
}

mode_is_private() {
  [ "$MODE" = "add_private" ]
}

show_mode_banner() {
  say ""
  case "$MODE" in
    auto)
      say "${YELLOW}INFO${NC}  Полный авторежим ведёт роутер от базовой подготовки до готового Podkop."
      say "Если на одном из шагов потребуется ребут, после загрузки просто снова запусти 'warren' — сценарий продолжится."
      ;;
    add_private|manage_private)
      say "${YELLOW}INFO${NC}  Amnezia Private использует AmneziaWG на интерфейсе awg0."
      ;;
    podkop_backup)
      say "${YELLOW}INFO${NC}  Режим резервного канала переведёт Podkop на URLTest с несколькими VLESS."
      ;;
    qos_private)
      say "${YELLOW}INFO${NC}  QoS для Amnezia управляет DSCP-профилями клиентов через nft."
      ;;
    remote_admin|remote_admin_config|remote_admin_poll_now|remote_admin_router_install|remote_admin_vps_install)
      say "${YELLOW}INFO${NC}  Remote Admin можно сначала сохранить как конфиг, а router/VPS helper'ы поставить отдельными шагами."
      ;;
    amnezia_client_create|amnezia_client_delete|manage_private)
      say "${YELLOW}INFO${NC}  Управление Amnezia-клиентами работает через тот же backend, что shell, LuCI и TG."
      ;;
    sni_checker)
      say "${YELLOW}INFO${NC}  SNI-checker подготовит и запустит на VPS read-only проверку кандидатов для Reality."
      say "3x-ui, Xray, firewall и конфиги трогаться не будут."
      ;;
    sni_apply)
      say "${YELLOW}INFO${NC}  Применение SNI обновит Warren Reality inbound, VLESS report и Podkop после подтверждения."
      ;;
    naiveproxy_wip)
      say "${YELLOW}INFO${NC}  Здесь будет сценарий настройки NaiveProxy."
      ;;
    shadowsocks_fallback_wip)
      say "${YELLOW}INFO${NC}  Здесь будет сценарий fallback на Shadowsocks."
      ;;
    rf_bundle_wip)
      say "${YELLOW}INFO${NC}  Здесь будет сценарий установки Warren из локального пакета внутри РФ-сегмента."
      ;;
  esac
}

mode_target_state() {
  case "$MODE" in
    basic) echo 75 ;;
    podkop_setup) echo 95 ;;
    auto) echo 100 ;;
    add_private) echo 120 ;;
    *) echo 0 ;;
  esac
}

mode_is_one_shot_service() {
  case "${MODE:-}" in
    basic|auto|add_private|podkop_setup) return 1 ;;
    *) return 0 ;;
  esac
}

auto_require_saved_inputs() {
  [ "$MODE" = "auto" ] || return 0

  if [ -z "${AUTO_VPS_SOURCE:-}" ]; then
    if [ "${WARREN_LUCI_REQUEST:-0}" = "1" ]; then
      fail "Для полного авторежима из LuCI не сохранён источник proxy-конфига. Заполни форму авторежима и запусти снова."
    fi
    fail "Для полного авторежима не сохранён источник proxy-конфига. Запусти пункт 0 заново."
  fi

  case "$AUTO_VPS_SOURCE" in
    new_vps)
      [ -n "${VPS_HOST:-}" ] || fail "Для полного авторежима не сохранён IP адрес VPS."
      [ -n "${VPS_SSH_PORT:-}" ] || fail "Для полного авторежима не сохранён SSH порт VPS."
      [ -n "${VPS_ROOT_PASSWORD:-}" ] || fail "Для полного авторежима не сохранён root пароль VPS."
      ;;
    report)
      [ -n "${SELECTED_VPS_REPORT:-}" ] || fail "Для полного авторежима не сохранён выбранный VPS-отчёт."
      [ -r "${SELECTED_VPS_REPORT:-}" ] || fail "Не найден выбранный VPS-отчёт: ${SELECTED_VPS_REPORT:-}"
      ;;
    link)
      [ -n "${VLESS:-}" ] || fail "Для полного авторежима не сохранена ссылка конфигурации."
      proxy_link_supported "${VLESS:-}" || fail "Сохранённая ссылка конфигурации не поддерживается Podkop."
      ;;
    *)
      fail "Неизвестный источник proxy-конфига для авторежима: $AUTO_VPS_SOURCE"
      ;;
  esac
}

prepare_auto_proxy_source() {
  [ "$MODE" = "auto" ] || return 0

  st="$(get_state)"
  if [ "$st" -ge 85 ]; then
    case "${AUTO_VPS_SOURCE:-}" in
      new_vps|report)
        if [ -z "${VLESS:-}" ] && [ -n "${SELECTED_VPS_REPORT:-}" ]; then
          VLESS="$(vps_report_vless_link "${SELECTED_VPS_REPORT:-}")"
          if [ -n "${VLESS:-}" ]; then
            conf_set VLESS "$VLESS"
          fi
        fi
        [ -n "${VLESS:-}" ] || fail "Auto resume: proxy-ссылка уже должна быть подготовлена, но VLESS пустой."
        proxy_link_supported "${VLESS:-}" || fail "Auto resume: сохранённая proxy-ссылка не поддерживается Podkop."
        runtime_state_set "vless" "$VLESS"
        runtime_state_set "selected_vps_report" "${SELECTED_VPS_REPORT:-}"
        return 0
        ;;
      link)
        [ -n "${VLESS:-}" ] || fail "Auto resume: сохранённая proxy-ссылка пуста."
        proxy_link_supported "${VLESS:-}" || fail "Auto resume: сохранённая proxy-ссылка не поддерживается Podkop."
        runtime_state_set "vless" "$VLESS"
        runtime_state_set "selected_vps_report" ""
        return 0
        ;;
    esac
  fi

  case "${AUTO_VPS_SOURCE:-}" in
    new_vps)
      run_vps_flow
      REPORT_FILE="${REPORT_FILE:-$(vps_report_file)}"
      if [ -r "$REPORT_FILE" ]; then
        SELECTED_VPS_REPORT="$REPORT_FILE"
        conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
        runtime_state_set "selected_vps_report" "$SELECTED_VPS_REPORT"
      fi
      [ -n "${VLESS:-}" ] || VLESS="$(vps_report_vless_link "${SELECTED_VPS_REPORT:-}")"
      [ -n "${VLESS:-}" ] || fail "После настройки VPS не удалось получить proxy-ссылку для Podkop."
      proxy_link_supported "${VLESS:-}" || fail "После настройки VPS получена неподдерживаемая ссылка конфигурации."
      conf_set VLESS "$VLESS"
      runtime_state_set "vless" "$VLESS"
      ;;
    report)
      VLESS="$(vps_report_vless_link "${SELECTED_VPS_REPORT:-}")"
      [ -n "${VLESS:-}" ] || fail "Не удалось получить proxy-ссылку из выбранного VPS-отчёта."
      proxy_link_supported "${VLESS:-}" || fail "Ссылка из выбранного VPS-отчёта не поддерживается Podkop."
      conf_set VLESS "$VLESS"
      runtime_state_set "vless" "$VLESS"
      runtime_state_set "selected_vps_report" "${SELECTED_VPS_REPORT:-}"
      ;;
    link)
      [ -n "${VLESS:-}" ] || fail "Ссылка конфигурации пуста."
      proxy_link_supported "${VLESS:-}" || fail "Ссылка конфигурации не поддерживается Podkop."
      SELECTED_VPS_REPORT=""
      conf_set SELECTED_VPS_REPORT ""
      runtime_state_set "vless" "$VLESS"
      runtime_state_set "selected_vps_report" ""
      ;;
  esac

  st="$(get_state)"
  if [ "$st" -lt 85 ]; then
    set_state 85
  fi
}

ensure_warren_ui_for_auto() {
  [ "$MODE" = "auto" ] || return 0

  if [ -x /usr/bin/warren ] && [ -r /usr/libexec/warren/warren-luci-run ] \
    && [ -r /usr/lib/lua/luci/controller/warren.lua ] && [ -r /usr/lib/lua/luci/view/warren/index.htm ]; then
    st="$(get_state)"
    if [ "$st" -lt 80 ]; then
      set_state 80
    fi
    done_ "UI Warren уже установлен"
    return 0
  fi

  install_warren_luci_ui
  set_state 80
}

print_component_status_line() {
  label="$1"
  status="$2"
  detail="$3"

  if [ -n "$detail" ]; then
    say "$label: $status ($detail)"
  else
    say "$label: $status"
  fi
}

print_installed_components_summary() {
  say "Installed components:"

  if [ -x /usr/bin/warren ]; then
    print_component_status_line "  Warren launcher" "installed" "/usr/bin/warren"
  else
    print_component_status_line "  Warren launcher" "missing" "/usr/bin/warren"
  fi

  if [ -r /usr/lib/lua/luci/controller/warren.lua ] && [ -r /usr/lib/lua/luci/view/warren/index.htm ]; then
    print_component_status_line "  Warren LuCI" "installed" "Services -> Warren"
  else
    print_component_status_line "  Warren LuCI" "missing" ""
  fi

  if uci -q get podkop.main >/dev/null 2>&1; then
    print_component_status_line "  Podkop" "configured" "$(uci -q get podkop.main.proxy_config_type 2>/dev/null || echo unknown)"
  else
    print_component_status_line "  Podkop" "not configured" ""
  fi

  if uci -q get network."$(podkop_private_iface)".proto 2>/dev/null | grep -qx 'amneziawg'; then
    print_component_status_line "  AmneziaWG" "configured" "$(podkop_private_iface)"
  else
    print_component_status_line "  AmneziaWG" "not configured" ""
  fi

  if [ -x /etc/init.d/warren-tg-bot ]; then
    print_component_status_line "  Telegram bot" "installed" "/etc/init.d/warren-tg-bot"
  else
    print_component_status_line "  Telegram bot" "not installed" ""
  fi
}

print_podkop_proxy_summary() {
  podkop_mode="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || echo unknown)"
  say "Podkop mode: $podkop_mode"
  say "Current proxy link(s):"

  proxy_links="$(podkop_current_proxy_links | sed '/^$/d' || true)"
  if [ -n "$proxy_links" ]; then
    proxy_index=1
    printf "%s\n" "$proxy_links" | while IFS= read -r proxy_link; do
      [ -n "$proxy_link" ] || continue
      say "  $proxy_index) $proxy_link"
      proxy_index=$((proxy_index + 1))
    done
  elif [ -n "${VLESS:-}" ]; then
    say "  1) $VLESS"
  else
    say "  unknown"
  fi
}

print_auto_final_summary() {
  [ "$MODE" = "auto" ] || return 0

  st="$(get_state)"
  if [ "$st" -lt 100 ]; then
    set_state 100
  fi

  say ""
  say "=== Итог полного авторежима ==="
  say "OpenWrt: $(openwrt_release_version)"
  say "Auto proxy source: ${AUTO_VPS_SOURCE:-unknown}"
  print_installed_components_summary
  print_podkop_proxy_summary

  if [ -r "${SELECTED_VPS_REPORT:-}" ]; then
    say ""
    say "Доступы к VPS / 3x-ui:"
    sed -n '/^Host:/p;/^SSH port:/p;/^SSH root password:/p;/^3x-ui URL:/p;/^3x-ui username:/p;/^3x-ui password:/p;/^VLESS inbound link:/p' "$SELECTED_VPS_REPORT"
  fi

  say ""
  say "=== Текущий Warren config ($CONF) ==="
  cat "$CONF" 2>/dev/null || true
  say ""

  if uci -q get podkop.main >/dev/null 2>&1; then
    say "=== Текущий UCI config Podkop ==="
    uci show podkop 2>/dev/null || true
    say ""
  fi
}

run_rf_bundle_wip_flow() {
  say ""
  say "${YELLOW}WIP${NC}  Milestone 10: здесь будет режим установки Warren из локального архива внутри РФ-сегмента."
  say "План: один bundle с warren.sh, lib и assets, который роутер сможет скачать и распаковать без GitHub raw."
  done_ "Режим РФ-сегмента пока в разработке"
}

run_naiveproxy_wip_flow() {
  say ""
  say "${YELLOW}WIP${NC}  Milestone 12: здесь будет сценарий настройки NaiveProxy."
  say "Пока оставляем раздел как placeholder, без детальной логики."
  done_ "NaiveProxy пока в разработке"
}

run_shadowsocks_fallback_wip_flow() {
  say ""
  say "${YELLOW}WIP${NC}  Milestone 8: здесь будет fallback-сценарий на Shadowsocks."
  say "Пока оставляем раздел как placeholder, без детальной логики."
  done_ "Shadowsocks fallback пока в разработке"
}

should_resume_current_mode() {
  target="$(mode_target_state)"
  st="$(get_state)"

  if [ "${MODE:-}" = "auto" ] && [ -z "${AUTO_VPS_SOURCE:-}" ]; then
    return 1
  fi

  if [ "$target" -gt 0 ] && [ "$st" -gt 0 ] && [ "$st" -lt "$target" ]; then
    return 0
  fi
  return 1
}

run_basic_flow() {
  print_progress

  st="$(get_state)"
  log "state=$st mode=$MODE"
  if [ "$st" -lt 10 ]; then
    basic_stage_note preflight
    check_openwrt
    set_state 10
  fi

  st="$(get_state)"
  if [ "$st" -lt 20 ]; then
    check_inet
    set_state 20
  fi

  st="$(get_state)"
  if [ "$st" -lt 30 ]; then
    sync_time
    set_state 30
  fi

  st="$(get_state)"
  if [ "$st" -lt 40 ]; then
    basic_stage_note packages
    if install_full_pkg_list; then
      set_state 40
    else
      warn "Установка пакетов упала (часто из-за места). Всё равно попробую expand-root, затем повторю установку."
      set_state 35
    fi
  fi

  st="$(get_state)"
  if [ "$st" -lt 45 ]; then
    basic_stage_note overlay
    check_space_overlay
    set_state 45
  fi

  st="$(get_state)"
  if [ "$st" -lt 50 ]; then
    overlay_report_and_prepare_expand
    expand_root_prep
    set_state 50
  fi

  st="$(get_state)"
  if [ "$st" -lt 60 ]; then
    basic_stage_note reboot
    expand_root_run_and_reboot
  fi

  st="$(get_state)"
  if [ "$st" -lt 70 ]; then
    basic_stage_note post_reboot
    install_full_pkg_list
    set_state 70
  fi

  st="$(get_state)"
  if [ "$st" -lt 75 ]; then
    check_space_overlay
    set_state 75
  fi
}

run_podkop_flow() {
  warren_require_sane_time "Podkop"

  case "$MODE" in
    podkop_backup)
      add_podkop_backup_channel
      ;;
    *)
      st="$(get_state)"
      if [ "$st" -lt 90 ]; then
        install_podkop
        set_state 90
      fi
      if [ "$st" -lt 95 ]; then
        configure_podkop_full
        watchdog_enable
        if [ "$MODE" != "auto" ]; then
          set_state 95
        fi
      fi
      ;;
  esac
}

run_remote_admin_console() {
  remote_control="${SCRIPT_DIR}/tools/remote-admin/warren-remote-control.sh"
  [ -x "$remote_control" ] || [ -r "$remote_control" ] || fail "Mac Remote Admin control script not found: $remote_control"
  exec sh "$remote_control"
}

run_service_mode() {
  case "$MODE" in
    initialize) install_warren_luci_ui ;;
    vps) run_vps_flow ;;
    podkop_backup) add_podkop_backup_channel ;;
    sni_checker) run_sni_checker_flow ;;
    sni_apply) run_sni_apply_flow ;;
    naiveproxy_wip) run_naiveproxy_wip_flow ;;
    shadowsocks_fallback_wip) run_shadowsocks_fallback_wip_flow ;;
    rf_bundle_wip) run_rf_bundle_wip_flow ;;
    qos_private) run_qos_flow ;;
    amnezia_client_create) run_amnezia_client_create_flow ;;
    amnezia_client_delete) run_amnezia_client_delete_flow ;;
    remote_admin_config) run_remote_admin_config_flow ;;
    remote_admin_poll_now) remote_admin_poll_now_flow ;;
    remote_admin_router_install) remote_admin_install_router_agent ;;
    remote_admin_vps_install) remote_admin_install_vps_helper ;;
    watchdog_enable) watchdog_enable ;;
    watchdog_disable) watchdog_disable ;;
    watchdog_reset) watchdog_reset ;;
    remote_admin_console) run_remote_admin_console ;;
    remote_admin) run_remote_admin_flow ;;
    usb_modem) run_usb_modem_flow ;;
    tg_bot) run_tg_bot_flow ;;
    diagnostics) run_diagnostics_flow ;;
    diagnostics_emergency) DIAG_FORCE_FALLBACK=1 run_diagnostics_flow ;;
    manage_private) run_amnezia_manage_flow ;;
    *) return 1 ;;
  esac

  conf_set MODE ""
  cleanup_runtime_state
  exit 0
}

main() {
  if [ "${WARREN_CLI_ARG1:-}" = "remote" ]; then
    remote_control="${SCRIPT_DIR}/tools/remote-admin/warren-remote-control.sh"
    [ -x "$remote_control" ] || [ -r "$remote_control" ] || fail "Mac Remote Admin control script not found: $remote_control"
    shift 1
    exec sh "$remote_control" "$@"
  fi

  if [ "${WARREN_CLI_ARG1:-}" = "--watchdog" ]; then
    watchdog_cli "${WARREN_CLI_ARG2:-status}"
    exit 0
  fi

  warren_maybe_offer_update "$@"

  if [ "${WARREN_CLI_ARG1:-}" = "--apply-qos" ]; then
    MODE="qos_apply"
    run_qos_apply_only
    exit 0
  fi

  if [ "${WARREN_CLI_ARG1:-}" = "--install-luci" ]; then
    MODE="initialize"
    install_warren_luci_ui
    exit 0
  fi

  if [ "${WARREN_CLI_ARG1:-}" = "--luci-run" ]; then
    MODE="${WARREN_CLI_ARG2:-}"
    [ -n "$MODE" ] || fail "Не задан режим Warren для LuCI"
    WARREN_REQUESTED_LUCI_MODE="$MODE"
    LUCI_AUTO_VPS_SOURCE="${AUTO_VPS_SOURCE:-}"
    LUCI_SELECTED_VPS_REPORT="${SELECTED_VPS_REPORT:-}"
    LUCI_VLESS="${VLESS:-}"
    LUCI_BROWSER_EPOCH="${BROWSER_EPOCH:-}"
    LUCI_VPS_HOST="${VPS_HOST:-}"
    LUCI_VPS_SSH_PORT="${VPS_SSH_PORT:-}"
    LUCI_VPS_ROOT_PASSWORD="${VPS_ROOT_PASSWORD:-}"
    LUCI_TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    LUCI_TG_BOT_CHAT_ID="${TG_BOT_CHAT_ID:-}"
    LUCI_REMOTE_ADMIN_ROUTER_ID="${REMOTE_ADMIN_ROUTER_ID:-}"
    LUCI_REMOTE_ADMIN_ROUTER_NAME="${REMOTE_ADMIN_ROUTER_NAME:-}"
    LUCI_REMOTE_ADMIN_ENDPOINTS="${REMOTE_ADMIN_ENDPOINTS:-}"
    LUCI_REMOTE_ADMIN_VPS_USER="${REMOTE_ADMIN_VPS_USER:-}"
    LUCI_REMOTE_ADMIN_POLL_INTERVAL="${REMOTE_ADMIN_POLL_INTERVAL:-}"
    LUCI_REMOTE_ADMIN_REQUEST_TTL="${REMOTE_ADMIN_REQUEST_TTL:-}"
    LUCI_REMOTE_ADMIN_MAC_LUCI_PORT="${REMOTE_ADMIN_MAC_LUCI_PORT:-}"
    LUCI_REMOTE_ADMIN_LOCAL_SSH_PORT="${REMOTE_ADMIN_LOCAL_SSH_PORT:-}"
    LUCI_REMOTE_ADMIN_LOCAL_LUCI_PORT="${REMOTE_ADMIN_LOCAL_LUCI_PORT:-}"
    LUCI_REMOTE_ADMIN_ROUTER_KEY_PATH="${REMOTE_ADMIN_ROUTER_KEY_PATH:-}"
    LUCI_SNI_APPLY_SOURCE="${SNI_APPLY_SOURCE:-}"
    LUCI_SNI_NEW="${SNI_NEW:-}"
    LUCI_SNI_REPORT_PATH="${SNI_REPORT_PATH:-}"
    LUCI_AMZ_CLIENT_NAME="${AMZ_CLIENT_NAME:-}"
    LUCI_QOS_CLIENT_NAME="${QOS_CLIENT_NAME:-}"
    LUCI_QOS_PROFILE="${QOS_PROFILE:-}"
    load_conf_if_exists || true
    WARREN_PREVIOUS_MODE="${MODE:-}"
    WARREN_PREVIOUS_STATE="$(get_state)"
    MODE="$WARREN_REQUESTED_LUCI_MODE"
    WARREN_LUCI_REQUEST=1
    if [ "$MODE" = "basic" ]; then
      if [ "$WARREN_PREVIOUS_MODE" != "basic" ] || [ "${WARREN_PREVIOUS_STATE:-0}" -ge 75 ]; then
        set_state 0
      fi
    fi
    conf_set MODE "$MODE"
    luci_apply_form_overrides
  fi

  if [ "${WARREN_LUCI_REQUEST:-}" = "1" ]; then
    load_conf_if_exists || true
    luci_apply_form_overrides
  elif [ -f "$CONF" ]; then
    load_conf
    if mode_is_one_shot_service || ! should_resume_current_mode; then
      menu
      load_conf
    fi
  else
    menu
    load_conf
  fi

  clear_terminal
  print_banner
  show_mode_banner

  auto_require_saved_inputs

  run_service_mode || true

  if [ "$MODE" != "podkop_backup" ]; then
    run_basic_flow
  fi

  ensure_warren_ui_for_auto
  prepare_auto_proxy_source

  if mode_is_podkop; then
    run_podkop_flow
  fi

  if mode_is_private; then
    run_amnezia_private_flow
  fi

  if [ "${MODE:-}" = "auto" ]; then
    target="$(mode_target_state)"
    st="$(get_state)"
    if [ "$target" -gt 0 ] && [ "$st" -ge "$target" ]; then
      conf_set MODE ""
    fi
  fi

  print_auto_final_summary
  cleanup_runtime_state
  done_ "Готово. State=$(get_state). Логи: $LOG"
  say "Если был ребут — просто запусти тот же скрипт снова, он продолжит."
}

main "$@"
