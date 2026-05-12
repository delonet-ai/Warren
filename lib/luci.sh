luci_install_dir() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    fail "Initialize LuCI UI нужно запускать на OpenWrt от root."
  fi
}

luci_install_prereqs() {
  pkg_manager >/dev/null 2>&1 || fail "LuCI UI installer не нашёл поддерживаемый пакетный менеджер OpenWrt."

  if pkg_manager_is_opkg; then
    info "OpenWrt 24.10.x: проверяю LuCI/Lua runtime через opkg"
    pkg_ensure_installed luci-base luci-compat uhttpd rpcd
  fi

  if pkg_manager_is_apk; then
    info "OpenWrt 25.12.x: проверяю LuCI/Lua runtime через apk"
    missing=""
    for pkg in luci luci-lua-runtime luci-compat uhttpd rpcd; do
      pkg_is_installed "$pkg" || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
      # shellcheck disable=SC2086
      apk -U add $missing || fail "Не удалось установить LuCI runtime через apk."
    fi
  fi

  [ -d /usr/lib/lua/luci ] || fail "LuCI Lua runtime не найден после установки зависимостей."
  [ -d /www ] || fail "Каталог /www не найден после установки LuCI/uhttpd."
  [ -d /usr/share/luci/menu.d ] || mkdir -p /usr/share/luci/menu.d || fail "Не удалось создать /usr/share/luci/menu.d"
  [ -d /usr/share/rpcd/acl.d ] || mkdir -p /usr/share/rpcd/acl.d || fail "Не удалось создать /usr/share/rpcd/acl.d"
  [ -d /usr/libexec/warren ] || mkdir -p /usr/libexec/warren || fail "Не удалось создать /usr/libexec/warren"
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
  app_script="${WARREN_APP_DIR:-/root/warren/app}/warren.sh"
  [ -r "$app_script" ] || fail "Не найден persistent Warren app: $app_script"
  cat > "$tmp" <<EOF
#!/bin/sh
exec "$app_script" "\$@"
EOF
  mv "$tmp" "$target" || fail "Не удалось установить $target"
  chmod +x "$target" 2>/dev/null || true
}

install_warren_libs() {
  target_dir="/usr/lib/warren/lib"
  mkdir -p "$target_dir" || fail "Не удалось создать $target_dir"

  for lib in common.sh ui.sh state.sh basic.sh podkop.sh amneziawg.sh vps.sh amnezia.sh qos.sh remote_admin.sh usb_modem.sh tg_bot.sh diagnostics.sh sni_checker.sh luci.sh; do
    target_path="$target_dir/$lib"
    if source_path="$(luci_persistent_source "lib/$lib")"; then
      if [ "$source_path" != "$target_path" ]; then
        cp "$source_path" "$target_path" || fail "Не удалось установить библиотеку: $lib"
      fi
    elif [ -r "$SCRIPT_DIR/lib/$lib" ]; then
      cp "$SCRIPT_DIR/lib/$lib" "$target_path" || fail "Не удалось установить библиотеку: $lib"
    else
      wget -qO "$target_path" "$WARREN_LIB_BASE_URL/$lib" || fail "Не удалось скачать библиотеку: $lib"
    fi
  done
}

install_warren_assets() {
  target_dir="/usr/lib/warren/assets"
  mkdir -p "$target_dir" || fail "Не удалось создать $target_dir"

  for asset in sni-candidates.txt; do
    target_path="$target_dir/$asset"
    if source_path="$(luci_persistent_source "assets/$asset")"; then
      if [ "$source_path" != "$target_path" ]; then
        cp "$source_path" "$target_path" || fail "Не удалось установить ассет: $asset"
      fi
    elif [ -r "$SCRIPT_DIR/assets/$asset" ]; then
      cp "$SCRIPT_DIR/assets/$asset" "$target_path" || fail "Не удалось установить ассет: $asset"
    else
      wget -qO "$target_path" "$WARREN_ASSET_BASE_URL/$asset" || fail "Не удалось скачать ассет: $asset"
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
      set -a
      # shellcheck disable=SC1090
      . "$form_env"
      set +a
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

install_warren_luci_menu() {
  install_warren_luci_asset \
    "luci-app-warren/root/usr/share/luci/menu.d/luci-app-warren.json" \
    "/usr/share/luci/menu.d/luci-app-warren.json" \
    0644 \
    "luci-app-warren/root/usr/share/luci/menu.d/luci-app-warren.json"
}

install_warren_luci_acl() {
  install_warren_luci_asset \
    "luci-app-warren/root/usr/share/rpcd/acl.d/luci-app-warren.json" \
    "/usr/share/rpcd/acl.d/luci-app-warren.json" \
    0644 \
    "luci-app-warren/root/usr/share/rpcd/acl.d/luci-app-warren.json"
}

verify_warren_luci_ui() {
  [ -x /usr/bin/warren ] || fail "Проверка UI: /usr/bin/warren не установлен."
  [ -x /usr/libexec/warren/warren-luci-run ] || fail "Проверка UI: warren-luci-run не установлен."
  [ -r /usr/lib/lua/luci/controller/warren.lua ] || fail "Проверка UI: controller warren.lua не установлен."
  [ -r /usr/lib/lua/luci/view/warren/index.htm ] || fail "Проверка UI: view index.htm не установлен."
  [ -r /usr/share/luci/menu.d/luci-app-warren.json ] || fail "Проверка UI: menu.d JSON не установлен."
  [ -r /usr/share/rpcd/acl.d/luci-app-warren.json ] || fail "Проверка UI: rpcd ACL JSON не установлен."

  if command -v luac >/dev/null 2>&1; then
    luac -p /usr/lib/lua/luci/controller/warren.lua >/dev/null 2>&1 || fail "Проверка UI: Lua controller не проходит luac -p."
  fi
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
  install_warren_luci_menu
  install_warren_luci_acl
  verify_warren_luci_ui

  if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
  fi
  if [ -x /etc/init.d/rpcd ]; then
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
  fi

  done_ "Warren UI установлен. Открой LuCI: Services -> Warren."
}
