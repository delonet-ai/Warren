remote_admin_base_dir() {
  printf "%s/remote-admin" "${WARREN_BASE_DIR:-/etc/warren}"
}

remote_admin_router_agent_path() {
  printf "%s" "/usr/bin/warren-remote-agent"
}

remote_admin_router_init_path() {
  printf "%s" "/etc/init.d/warren-remote-admin"
}

remote_admin_router_conf_path() {
  printf "%s/warren-remote-admin.conf" "${WARREN_BASE_DIR:-/etc/warren}"
}

remote_admin_vps_helper_path() {
  printf "%s" "/usr/local/bin/warren-remote"
}

remote_admin_router_state_dir() {
  printf "%s/state" "$(remote_admin_base_dir)"
}

remote_admin_router_log_dir() {
  printf "%s/logs" "$(remote_admin_base_dir)"
}

remote_admin_router_runtime_dir() {
  printf "%s/runtime" "$(remote_admin_base_dir)"
}

remote_admin_default_router_id() {
  seed=""
  if [ -r /etc/machine-id ]; then
    seed="$(cat /etc/machine-id 2>/dev/null)"
  elif [ -r /var/lib/dbus/machine-id ]; then
    seed="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
  fi
  if [ -z "$seed" ]; then
    seed="$(hostname 2>/dev/null || printf "router")"
  fi
  printf "%s" "$seed" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//'
}

remote_admin_default_router_name() {
  hostname 2>/dev/null | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//' || printf "router"
}

remote_admin_default_endpoint() {
  if [ -n "${VPS_HOST:-}" ]; then
    printf "%s:%s" "$VPS_HOST" "${VPS_SSH_PORT:-22}"
    return 0
  fi
  printf ""
}

remote_admin_default_vps_user() {
  printf "%s" "root"
}

remote_admin_defaults_sync() {
  [ -n "${REMOTE_ADMIN_ROUTER_ID:-}" ] || REMOTE_ADMIN_ROUTER_ID="$(remote_admin_default_router_id)"
  [ -n "${REMOTE_ADMIN_ROUTER_NAME:-}" ] || REMOTE_ADMIN_ROUTER_NAME="$(remote_admin_default_router_name)"
  [ -n "${REMOTE_ADMIN_ENDPOINTS:-}" ] || REMOTE_ADMIN_ENDPOINTS="$(remote_admin_default_endpoint)"
  [ -n "${REMOTE_ADMIN_VPS_USER:-}" ] || REMOTE_ADMIN_VPS_USER="$(remote_admin_default_vps_user)"
  [ -n "${REMOTE_ADMIN_POLL_INTERVAL:-}" ] || REMOTE_ADMIN_POLL_INTERVAL="300"
  [ -n "${REMOTE_ADMIN_REQUEST_TTL:-}" ] || REMOTE_ADMIN_REQUEST_TTL="900"
  [ -n "${REMOTE_ADMIN_MAC_LUCI_PORT:-}" ] || REMOTE_ADMIN_MAC_LUCI_PORT="8081"
  [ -n "${REMOTE_ADMIN_MAC_SSH_PORT:-}" ] || REMOTE_ADMIN_MAC_SSH_PORT="2201"
  [ -n "${REMOTE_ADMIN_LOCAL_SSH_PORT:-}" ] || REMOTE_ADMIN_LOCAL_SSH_PORT="2201"
  [ -n "${REMOTE_ADMIN_LOCAL_LUCI_PORT:-}" ] || REMOTE_ADMIN_LOCAL_LUCI_PORT="8081"
  [ -n "${REMOTE_ADMIN_ROUTER_KEY_PATH:-}" ] || REMOTE_ADMIN_ROUTER_KEY_PATH="$(vps_key_file 2>/dev/null || printf "%s/remote-admin/router_ed25519" "$(remote_admin_base_dir)")"
  [ -n "${REMOTE_ADMIN_ENABLED:-}" ] || REMOTE_ADMIN_ENABLED="1"
}

remote_admin_save_config() {
  remote_admin_defaults_sync
  conf_set REMOTE_ADMIN_ROUTER_ID "$REMOTE_ADMIN_ROUTER_ID"
  conf_set REMOTE_ADMIN_ROUTER_NAME "$REMOTE_ADMIN_ROUTER_NAME"
  conf_set REMOTE_ADMIN_ENDPOINTS "$REMOTE_ADMIN_ENDPOINTS"
  conf_set REMOTE_ADMIN_VPS_USER "$REMOTE_ADMIN_VPS_USER"
  conf_set REMOTE_ADMIN_POLL_INTERVAL "$REMOTE_ADMIN_POLL_INTERVAL"
  conf_set REMOTE_ADMIN_REQUEST_TTL "$REMOTE_ADMIN_REQUEST_TTL"
  conf_set REMOTE_ADMIN_MAC_LUCI_PORT "$REMOTE_ADMIN_MAC_LUCI_PORT"
  conf_set REMOTE_ADMIN_LOCAL_SSH_PORT "$REMOTE_ADMIN_LOCAL_SSH_PORT"
  conf_set REMOTE_ADMIN_LOCAL_LUCI_PORT "$REMOTE_ADMIN_LOCAL_LUCI_PORT"
  conf_set REMOTE_ADMIN_ROUTER_KEY_PATH "$REMOTE_ADMIN_ROUTER_KEY_PATH"
}

remote_admin_summary() {
  remote_admin_defaults_sync
  say ""
  say "Remote Admin:"
  say "  router_id: ${REMOTE_ADMIN_ROUTER_ID:-unknown}"
  say "  router_name: ${REMOTE_ADMIN_ROUTER_NAME:-unknown}"
  say "  endpoints: ${REMOTE_ADMIN_ENDPOINTS:-unknown}"
  say "  vps_user: ${REMOTE_ADMIN_VPS_USER:-root}"
  say "  poll interval: ${REMOTE_ADMIN_POLL_INTERVAL:-300}s"
  say "  request ttl: ${REMOTE_ADMIN_REQUEST_TTL:-900}s"
  say "  mac browser port: ${REMOTE_ADMIN_MAC_LUCI_PORT:-8081}"
  if [ -n "${REMOTE_ADMIN_ROUTER_KEY_PATH:-}" ]; then
    say "  router key: ${REMOTE_ADMIN_ROUTER_KEY_PATH}"
  fi
}

remote_admin_install_prereqs() {
  missing=""
  command -v ssh >/dev/null 2>&1 || missing="$missing openssh-client"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    # shellcheck disable=SC2086
    pkg_ensure_installed $missing
  fi

  if [ -z "${WARREN_REMOTE_ADMIN_SKIP_AUTOSSH:-}" ] && ! command -v autossh >/dev/null 2>&1; then
    warn "autossh не установлен; Remote Admin будет использовать обычный ssh fallback"
  fi
}

remote_admin_write_router_agent() {
  target="$1"
  warren_install_payload warren-remote-agent "$target"
}

remote_admin_write_router_init() {
  target="$1"
  warren_install_payload warren-remote-admin.init "$target"
}

remote_admin_write_vps_helper() {
  target="$1"
  warren_install_payload warren-remote "$target"
}

remote_admin_install_router_agent() {
  remote_admin_install_prereqs
  remote_admin_defaults_sync
  mkdir -p "$(remote_admin_router_state_dir)" "$(remote_admin_router_log_dir)" "$(remote_admin_router_runtime_dir)" || fail "Не удалось создать каталоги Remote Admin"
  router_key_dir="$(dirname "$REMOTE_ADMIN_ROUTER_KEY_PATH")"
  mkdir -p "$router_key_dir" || fail "Не удалось создать каталог для router key"
  if [ ! -s "$REMOTE_ADMIN_ROUTER_KEY_PATH" ]; then
    command -v ssh-keygen >/dev/null 2>&1 || fail "Не найден ssh-keygen для генерации router key"
    ssh-keygen -q -t ed25519 -N "" -f "$REMOTE_ADMIN_ROUTER_KEY_PATH" || fail "Не удалось сгенерировать router key"
  fi
  [ -s "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" ] || ssh-keygen -y -f "$REMOTE_ADMIN_ROUTER_KEY_PATH" > "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" || fail "Не удалось подготовить router public key"
  chmod 600 "$REMOTE_ADMIN_ROUTER_KEY_PATH" 2>/dev/null || true
  chmod 644 "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" 2>/dev/null || true
  remote_admin_save_config

  agent_path="$(remote_admin_router_agent_path)"
  init_path="$(remote_admin_router_init_path)"
  conf_path="$(remote_admin_router_conf_path)"

  remote_admin_write_router_agent "$agent_path" || fail "Не удалось подготовить router-agent"
  chmod 700 "$agent_path" 2>/dev/null || true

  remote_admin_write_router_init "$init_path" || fail "Не удалось подготовить init script Remote Admin"
  chmod 755 "$init_path" 2>/dev/null || true

  {
    printf "REMOTE_ADMIN_ROUTER_ID=%s\n" "$REMOTE_ADMIN_ROUTER_ID"
    printf "REMOTE_ADMIN_ROUTER_NAME=%s\n" "$REMOTE_ADMIN_ROUTER_NAME"
    printf "REMOTE_ADMIN_ENDPOINTS=%s\n" "$REMOTE_ADMIN_ENDPOINTS"
    printf "REMOTE_ADMIN_VPS_USER=%s\n" "$REMOTE_ADMIN_VPS_USER"
    printf "REMOTE_ADMIN_POLL_INTERVAL=%s\n" "$REMOTE_ADMIN_POLL_INTERVAL"
    printf "REMOTE_ADMIN_REQUEST_TTL=%s\n" "$REMOTE_ADMIN_REQUEST_TTL"
    printf "REMOTE_ADMIN_MAC_LUCI_PORT=%s\n" "$REMOTE_ADMIN_MAC_LUCI_PORT"
    printf "REMOTE_ADMIN_LOCAL_SSH_PORT=%s\n" "$REMOTE_ADMIN_LOCAL_SSH_PORT"
    printf "REMOTE_ADMIN_LOCAL_LUCI_PORT=%s\n" "$REMOTE_ADMIN_LOCAL_LUCI_PORT"
    printf "REMOTE_ADMIN_ROUTER_KEY_PATH=%s\n" "$REMOTE_ADMIN_ROUTER_KEY_PATH"
    printf "REMOTE_ADMIN_ENABLED=%s\n" "1"
  } > "$conf_path"
  chmod 600 "$conf_path" 2>/dev/null || true

  if [ -x /etc/init.d/warren-remote-admin ]; then
    /etc/init.d/warren-remote-admin enable >/dev/null 2>&1 || true
    /etc/init.d/warren-remote-admin restart >/dev/null 2>&1 || true
  fi

  if command -v ssh >/dev/null 2>&1 && [ -s "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" ] && [ -n "${VPS_HOST:-}" ] && { [ -n "${VPS_ROOT_PASSWORD:-}" ] || [ -n "${VPS_KEY_PATH:-}" ]; }; then
    info "Публикую router key на VPS helper и готовлю каталог..."
    remote_admin_install_vps_helper || true
  fi

  vps_step_done "Router-side Remote Admin установлен"
}

remote_admin_install_vps_helper() {
  [ -n "${VPS_HOST:-}" ] || fail "Remote Admin VPS helper требует настроенный VPS"
  [ -n "${VPS_ROOT_PASSWORD:-}" ] || [ -n "${VPS_KEY_PATH:-}" ] || fail "Remote Admin VPS helper требует VPS root password или SSH key"

  local_helper="${TMPDIR:-/tmp}/warren-remote.$$"
  remote_admin_write_vps_helper "$local_helper" || fail "Не удалось подготовить VPS helper"
  chmod 700 "$local_helper" 2>/dev/null || true

  vps_ssh "mkdir -p /var/lib/warren-remote /usr/local/bin" || fail "Не удалось подготовить каталог warren-remote на VPS"
  vps_write_remote_file "$local_helper" "/usr/local/bin/warren-remote" || fail "Не удалось загрузить warren-remote helper на VPS"
  vps_ssh "chmod 700 /usr/local/bin/warren-remote && /usr/local/bin/warren-remote init" || fail "Не удалось инициализировать warren-remote на VPS"

  if [ -s "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" ]; then
    router_pubkey="$(cat "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" 2>/dev/null || true)"
    if [ -n "$router_pubkey" ]; then
      escaped_pubkey="$(quote_sh "$router_pubkey")"
      vps_ssh_password "sh -lc 'umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; grep -qxF $escaped_pubkey /root/.ssh/authorized_keys || printf \"%s\\n\" $escaped_pubkey >> /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys'" \
        || warn "Не удалось автоматически добавить router pubkey в authorized_keys на VPS; проверяю key-based SSH-доступ"
    fi
  fi

  if ! vps_ssh_key "printf '__WARREN_REMOTE_ADMIN_VPS_KEY_OK__\\n'"; then
    fail "Не удалось подтвердить key-based SSH-доступ router -> VPS"
  fi

  rm -f "$local_helper" >/dev/null 2>&1 || true
  vps_step_done "VPS Remote Admin helper установлен"
}

remote_admin_install_vps_bundle() {
  remote_admin_defaults_sync
  remote_admin_install_vps_helper || fail "Не удалось установить VPS-side Remote Admin helper"
}

remote_admin_poll_now_flow() {
  remote_admin_defaults_sync
  say ""
  say "Remote Admin: immediate poll"
  if [ ! -x "$(remote_admin_router_agent_path)" ]; then
    fail "Router agent is missing. Install Remote Admin on the router first."
  fi
  if /usr/bin/warren-remote-agent poll >/dev/null 2>&1; then
    done_ "Remote Admin poll triggered"
  else
    warn "Poll returned no response or no endpoint answered yet."
    done_ "Remote Admin poll triggered"
  fi
}

remote_admin_config_only() {
  remote_admin_defaults_sync
  remote_admin_save_config
  remote_admin_report_status
  done_ "Remote Admin settings saved"
}

remote_admin_report_status() {
  remote_admin_summary
  say "  router agent: $( [ -x "$(remote_admin_router_agent_path)" ] && printf installed || printf missing )"
  say "  router init: $( [ -x "$(remote_admin_router_init_path)" ] && printf installed || printf missing )"
  say "  router conf: $( [ -r "$(remote_admin_router_conf_path)" ] && printf installed || printf missing )"
}

run_remote_admin_flow() {
  say ""
  say "Remote Admin: on-demand reverse tunnel"
  remote_admin_defaults_sync
  remote_admin_save_config
  remote_admin_report_status
  say ""
  say "Flow:"
  say "  1) Router keeps a short polling loop to the VPS endpoint(s)."
  say "  2) VPS keeps a router catalog and can request any live router."
  say "  3) When requested, router opens reverse SSH ports for SSH and LuCI."
  say "  4) On the Mac, use tools/remote-admin/warren-remote-control.sh to request and open the UI."

  if ! detect_pkg_manager >/dev/null 2>&1; then
    warn "На этой системе нет OpenWrt package manager. Сохраняю только Remote Admin config, без установки router/VPS helper'ов."
    remote_admin_config_only || fail "Не удалось сохранить настройки Remote Admin"
    return 0
  fi

  if [ -z "${VPS_HOST:-}" ] || [ -z "${VPS_ROOT_PASSWORD:-}" ]; then
    warn "VPS host/password is not fully configured yet. Router install will still prepare local files."
    remote_admin_install_router_agent || fail "Не удалось установить router-side Remote Admin"
    done_ "Remote Admin router-side scaffold installed"
    return 0
  fi

  remote_admin_install_router_agent || fail "Не удалось установить router-side Remote Admin"
  remote_admin_install_vps_helper || fail "Не удалось установить VPS-side Remote Admin helper"

  say ""
  say "Mac control:"
  say "  tools/remote-admin/warren-remote-control.sh request <router-id>"
  say "  tools/remote-admin/warren-remote-control.sh connect <router-id>"
  say ""
  say "Router ID: ${REMOTE_ADMIN_ROUTER_ID}"
  say "VPS endpoint: ${REMOTE_ADMIN_ENDPOINTS}"
  done_ "Remote Admin scaffold installed for router and VPS"
}

run_remote_admin_config_flow() {
  say ""
  say "Remote Admin: save configuration only"
  remote_admin_config_only || fail "Не удалось сохранить настройки Remote Admin"
}
