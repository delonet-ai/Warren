luci_install_dir() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    fail "Initialize LuCI UI нужно запускать на OpenWrt от root."
  fi
}

luci_install_prereqs() {
  pkg_manager >/dev/null 2>&1 || fail "LuCI UI installer не нашёл поддерживаемый пакетный менеджер OpenWrt."

  missing=""
  [ -d /usr/lib/lua/luci ] || missing="$missing luci-base"
  [ -d /www ] || missing="$missing uhttpd"
  if pkg_manager_is_opkg && ! pkg_is_installed luci-compat; then
    missing="$missing luci-compat"
  fi

  if [ -n "$missing" ]; then
    info "Ставлю зависимости Warren UI:$missing"
    # shellcheck disable=SC2086
    pkg_ensure_installed $missing
  fi
}

luci_write_file() {
  path="$1"
  mode="$2"
  dir="$(dirname "$path")"
  mkdir -p "$dir" || fail "Не удалось создать каталог: $dir"
  tmp="/tmp/warren-luci.$$.tmp"
  cat > "$tmp" || fail "Не удалось подготовить файл: $path"
  mv "$tmp" "$path" || fail "Не удалось записать файл: $path"
  chmod "$mode" "$path" 2>/dev/null || true
}

luci_persistent_source() {
  rel_path="$1"
  case "$rel_path" in
    warren.sh)
      candidate="${WARREN_APP_DIR:-/root/warren/app}/warren.sh"
      ;;
    lib/*)
      candidate="/usr/lib/warren/${rel_path}"
      ;;
    assets/*)
      candidate="/usr/lib/warren/${rel_path}"
      ;;
    *)
      return 1
      ;;
  esac
  [ -r "$candidate" ] || return 1
  printf "%s" "$candidate"
}

install_warren_binary() {
  target="/usr/bin/warren"
  tmp="/tmp/warren-bin.$$.tmp"
  if source_path="$(luci_persistent_source "warren.sh")"; then
    cp "$source_path" "$tmp" || fail "Не удалось подготовить /usr/bin/warren"
  elif [ -r "$SCRIPT_DIR/warren.sh" ]; then
    cp "$SCRIPT_DIR/warren.sh" "$tmp" || fail "Не удалось подготовить /usr/bin/warren"
  else
    wget -qO "$tmp" "$WARREN_RAW_BASE_URL/warren.sh" || fail "Не удалось скачать warren.sh"
  fi
  mv "$tmp" "$target" || fail "Не удалось установить $target"
  chmod +x "$target" 2>/dev/null || true
}

install_warren_libs() {
  target_dir="/usr/lib/warren/lib"
  mkdir -p "$target_dir" || fail "Не удалось создать $target_dir"

  for lib in common.sh ui.sh state.sh basic.sh podkop.sh amneziawg.sh vps.sh amnezia.sh qos.sh remote_admin.sh usb_modem.sh tg_bot.sh diagnostics.sh sni_checker.sh luci.sh; do
    if source_path="$(luci_persistent_source "lib/$lib")"; then
      cp "$source_path" "$target_dir/$lib" || fail "Не удалось установить библиотеку: $lib"
    elif [ -r "$SCRIPT_DIR/lib/$lib" ]; then
      cp "$SCRIPT_DIR/lib/$lib" "$target_dir/$lib" || fail "Не удалось установить библиотеку: $lib"
    else
      wget -qO "$target_dir/$lib" "$WARREN_LIB_BASE_URL/$lib" || fail "Не удалось скачать библиотеку: $lib"
    fi
  done
}

install_warren_assets() {
  target_dir="/usr/lib/warren/assets"
  mkdir -p "$target_dir" || fail "Не удалось создать $target_dir"

  for asset in sni-candidates.txt; do
    if source_path="$(luci_persistent_source "assets/$asset")"; then
      cp "$source_path" "$target_dir/$asset" || fail "Не удалось установить ассет: $asset"
    elif [ -r "$SCRIPT_DIR/assets/$asset" ]; then
      cp "$SCRIPT_DIR/assets/$asset" "$target_dir/$asset" || fail "Не удалось установить ассет: $asset"
    else
      wget -qO "$target_dir/$asset" "$WARREN_ASSET_BASE_URL/$asset" || fail "Не удалось скачать ассет: $asset"
    fi
  done
}

install_warren_version_file() {
  target="/usr/lib/warren/VERSION"
  mkdir -p "$(dirname "$target")" || fail "Не удалось создать каталог для $target"

  if [ -r "$SCRIPT_DIR/VERSION" ]; then
    cp "$SCRIPT_DIR/VERSION" "$target" || fail "Не удалось установить VERSION"
  else
    wget -qO "$target" "$WARREN_RAW_BASE_URL/VERSION" || fail "Не удалось скачать VERSION"
  fi
  chmod 644 "$target" 2>/dev/null || true
}

install_warren_luci_runner() {
  luci_write_file /usr/libexec/warren/warren-luci-run 0755 <<'EOF'
#!/bin/sh

mode="$1"
[ -n "$mode" ] || {
  echo "Usage: warren-luci-run <mode>" >&2
  exit 2
}

job="/tmp/warren-luci-job"
log="${job}.log"
pidfile="${job}.pid"
form_env="${job}.env"

if [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  echo "Warren job is already running: $(cat "$pidfile")"
  exit 0
fi

(
  echo "$$" > "$pidfile"
  {
    echo "=== Warren LuCI job: $mode ==="
    date
    echo
    if [ -r "$form_env" ]; then
      # shellcheck disable=SC1090
      . "$form_env"
    fi
    WARREN_LUCI=1 WARREN_USE_LOCAL_LIBS=1 WARREN_BASE_DIR=/etc/warren WARREN_LOG_DIR=/root/warren /usr/bin/warren --luci-run "$mode"
    rc=$?
    echo
    echo "=== exit code: $rc ==="
    date
    rm -f "$pidfile"
    exit "$rc"
  } > "$log" 2>&1
) &

echo "Started Warren job: $mode"
EOF
}

install_warren_luci_asset() {
  source_path="$1"
  target_path="$2"
  mode="$3"
  raw_path="$4"

  mkdir -p "$(dirname "$target_path")" || fail "Не удалось создать каталог для $target_path"
  if persistent_path="$(luci_persistent_source "$source_path")"; then
    cp "$persistent_path" "$target_path" || fail "Не удалось установить $target_path"
  elif [ -r "$SCRIPT_DIR/$source_path" ]; then
    cp "$SCRIPT_DIR/$source_path" "$target_path" || fail "Не удалось установить $target_path"
  else
    wget -qO "$target_path" "$WARREN_RAW_BASE_URL/$raw_path" || fail "Не удалось скачать $target_path"
  fi
  chmod "$mode" "$target_path" 2>/dev/null || true
}

install_warren_luci_controller() {
  install_warren_luci_asset \
    "luci-app-warren/luasrc/controller/warren.lua" \
    "/usr/lib/lua/luci/controller/warren.lua" \
    0644 \
    "luci-app-warren/luasrc/controller/warren.lua"
}

install_warren_luci_view() {
  install_warren_luci_asset \
    "luci-app-warren/luasrc/view/warren/index.htm" \
    "/usr/lib/lua/luci/view/warren/index.htm" \
    0644 \
    "luci-app-warren/luasrc/view/warren/index.htm"
}

install_warren_luci_ui() {
  luci_install_dir
  luci_install_prereqs
  install_warren_binary
  install_warren_libs
  install_warren_assets
  install_warren_version_file
  install_warren_luci_runner
  install_warren_luci_controller
  install_warren_luci_view

  if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
  fi

  done_ "Warren UI установлен. Открой LuCI: Services -> Warren."
}
