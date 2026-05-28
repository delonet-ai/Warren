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
  cat > "$target" <<'EOF'
#!/bin/sh
set -eu

CONFIG="${WARREN_REMOTE_ADMIN_CONFIG:-/etc/warren/warren-remote-admin.conf}"
STATE_DIR="${WARREN_REMOTE_ADMIN_RUNTIME_DIR:-/var/run/warren-remote-admin}"
LOG_FILE="${WARREN_REMOTE_ADMIN_LOG_FILE:-/tmp/warren-remote-admin.log}"
PID_FILE="${STATE_DIR}/tunnel.pid"
CURRENT_PORTS_FILE="${STATE_DIR}/tunnel.ports"
DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
LAST_POLL_FILE="${STATE_DIR}/last-poll.env"

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

log() {
  printf "[%s] %s\n" "$(date +'%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG_FILE"
}

safe_text() {
  printf "%s" "$1" | tr ' ' '_'
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf "%s" "$1" | sha256sum | awk '{print $1}'
  else
    printf "%s" "$1" | cksum | awk '{print $1}'
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf "%s" "$1" | sha256sum | awk '{print $1}'
  else
    printf "%s" "$1" | cksum | awk '{print $1}'
  fi
}

load_config() {
  [ -r "$CONFIG" ] || return 1
  # shellcheck disable=SC1090
  . "$CONFIG"
  [ -n "${REMOTE_ADMIN_ROUTER_ID:-}" ] || return 1
  [ -n "${REMOTE_ADMIN_ROUTER_NAME:-}" ] || REMOTE_ADMIN_ROUTER_NAME="${REMOTE_ADMIN_ROUTER_ID}"
  [ -n "${REMOTE_ADMIN_ENDPOINTS:-}" ] || return 1
  [ -n "${REMOTE_ADMIN_VPS_USER:-}" ] || REMOTE_ADMIN_VPS_USER="root"
  [ -n "${REMOTE_ADMIN_POLL_INTERVAL:-}" ] || REMOTE_ADMIN_POLL_INTERVAL="30"
  [ -n "${REMOTE_ADMIN_REQUEST_TTL:-}" ] || REMOTE_ADMIN_REQUEST_TTL="900"
  [ -n "${REMOTE_ADMIN_LOCAL_SSH_PORT:-}" ] || REMOTE_ADMIN_LOCAL_SSH_PORT="2201"
  [ -n "${REMOTE_ADMIN_LOCAL_LUCI_PORT:-}" ] || REMOTE_ADMIN_LOCAL_LUCI_PORT="8081"
  [ -n "${REMOTE_ADMIN_ROUTER_KEY_PATH:-}" ] || return 1
  return 0
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR" >/dev/null 2>&1 || return 1
}

endpoint_candidates() {
  printf "%s\n" "${REMOTE_ADMIN_ENDPOINTS:-}" | tr ',;' '\n' | sed '/^$/d'
}

split_endpoint() {
  endpoint="$1"
  host="${endpoint%:*}"
  port="${endpoint##*:}"
  case "$endpoint" in
    *:*)
      if printf "%s" "$port" | grep -Eq '^[0-9]+$'; then
        printf "%s %s" "$host" "$port"
      else
        printf "%s %s" "$endpoint" "22"
      fi
      ;;
    *)
      printf "%s %s" "$endpoint" "22"
      ;;
  esac
}

ssh_base() {
  ssh \
    -i "$REMOTE_ADMIN_ROUTER_KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=10 \
    "$@"
}

helper_call() {
  endpoint="$1"
  shift
  set -- $(split_endpoint "$endpoint") "$@"
  host="$1"
  port="$2"
  shift 2
  ssh_base -p "$port" "${REMOTE_ADMIN_VPS_USER}@${host}" "warren-remote $*"
}

current_pid() {
  [ -s "$PID_FILE" ] || return 1
  cat "$PID_FILE" 2>/dev/null
}

pid_is_alive() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" >/dev/null 2>&1
}

discover_tunnel_pid() {
  tunnel_ssh_port="${1:-}"
  tunnel_luci_port="${2:-}"
  ps w 2>/dev/null | awk -v ssh_port="$tunnel_ssh_port" -v luci_port="$tunnel_luci_port" '
    (index($0, "ssh") || index($0, "autossh")) &&
    index($0, "-R 127.0.0.1:" ssh_port ":127.0.0.1:22") &&
    index($0, "-R 127.0.0.1:" luci_port ":127.0.0.1:80") { print $1; exit }
  '
}

ports_from_file() {
  [ -r "$CURRENT_PORTS_FILE" ] || return 1
  sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" | head -n1
  sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" | head -n1
}

stop_tunnel() {
  if pid="$(current_pid 2>/dev/null || true)"; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE" "$CURRENT_PORTS_FILE" >/dev/null 2>&1 || true
}

write_last_poll() {
  {
    printf "LAST_POLL_AT=%s\n" "$(now_epoch)"
    printf "LAST_POLL_ACTION=%s\n" "${1:-}"
    printf "LAST_POLL_ENDPOINT=%s\n" "${2:-}"
    printf "LAST_POLL_RESULT=%s\n" "${3:-}"
    printf "LAST_POLL_REQUEST_ID=%s\n" "${4:-}"
  } > "$LAST_POLL_FILE"
}

tunnel_running() {
  if pid="$(current_pid 2>/dev/null || true)"; then
    if pid_is_alive "$pid"; then
      return 0
    fi
  fi
  if [ -r "$CURRENT_PORTS_FILE" ]; then
    tunnel_pid="$(discover_tunnel_pid "$(sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)" "$(sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)")"
    if pid_is_alive "$tunnel_pid"; then
      printf "%s\n" "$tunnel_pid" > "$PID_FILE" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

start_tunnel() {
  endpoint_host="$1"
  endpoint_port="$2"
  tunnel_ssh_port="$3"
  tunnel_luci_port="$4"

  mkdir -p "$STATE_DIR" >/dev/null 2>&1 || return 1

  if tunnel_running; then
    existing_ssh_port="$(sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1 || true)"
    existing_luci_port="$(sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1 || true)"
    if [ "$existing_ssh_port" = "$tunnel_ssh_port" ] && [ "$existing_luci_port" = "$tunnel_luci_port" ]; then
      return 0
    fi
    stop_tunnel
  fi

  if command -v autossh >/dev/null 2>&1; then
    tunnel_cmd="exec autossh -M 0 -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -i \"$REMOTE_ADMIN_ROUTER_KEY_PATH\" -p \"$endpoint_port\" -R 127.0.0.1:${tunnel_ssh_port}:127.0.0.1:22 -R 127.0.0.1:${tunnel_luci_port}:127.0.0.1:80 ${REMOTE_ADMIN_VPS_USER}@${endpoint_host}"
  else
    tunnel_cmd="exec ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -i \"$REMOTE_ADMIN_ROUTER_KEY_PATH\" -p \"$endpoint_port\" -R 127.0.0.1:${tunnel_ssh_port}:127.0.0.1:22 -R 127.0.0.1:${tunnel_luci_port}:127.0.0.1:80 ${REMOTE_ADMIN_VPS_USER}@${endpoint_host}"
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null &
  fi

  pid="$!"
  printf "%s\n" "$pid" > "$PID_FILE"
  {
    printf "TUNNEL_SSH_PORT=%s\n" "$tunnel_ssh_port"
    printf "TUNNEL_LUCI_PORT=%s\n" "$tunnel_luci_port"
    printf "TUNNEL_STARTED_AT=%s\n" "$(now_epoch)"
  } > "$CURRENT_PORTS_FILE"

  sleep 2
  if tunnel_running; then
    log "tunnel started: ssh=${tunnel_ssh_port} luci=${tunnel_luci_port} pid=${pid}"
    return 0
  fi

  log "tunnel failed to start"
  stop_tunnel
  return 1
}

report_status() {
  printf "ROUTER_ID=%s\n" "${REMOTE_ADMIN_ROUTER_ID:-}"
  printf "ROUTER_NAME=%s\n" "${REMOTE_ADMIN_ROUTER_NAME:-}"
  printf "ENDPOINTS=%s\n" "${REMOTE_ADMIN_ENDPOINTS:-}"
  printf "VPS_USER=%s\n" "${REMOTE_ADMIN_VPS_USER:-}"
  printf "POLL_INTERVAL=%s\n" "${REMOTE_ADMIN_POLL_INTERVAL:-}"
  printf "REQUEST_TTL=%s\n" "${REMOTE_ADMIN_REQUEST_TTL:-}"
  printf "LOCAL_SSH_PORT=%s\n" "${REMOTE_ADMIN_LOCAL_SSH_PORT:-}"
  printf "LOCAL_LUCI_PORT=%s\n" "${REMOTE_ADMIN_LOCAL_LUCI_PORT:-}"
  if [ -r "$LAST_POLL_FILE" ]; then
    sed -n 's/^LAST_POLL_AT=/LAST_POLL_AT=/p;s/^LAST_POLL_ACTION=/LAST_POLL_ACTION=/p;s/^LAST_POLL_ENDPOINT=/LAST_POLL_ENDPOINT=/p;s/^LAST_POLL_RESULT=/LAST_POLL_RESULT=/p;s/^LAST_POLL_REQUEST_ID=/LAST_POLL_REQUEST_ID=/p' "$LAST_POLL_FILE"
  fi
  if [ -s "$DAEMON_PID_FILE" ]; then
    daemon_pid="$(cat "$DAEMON_PID_FILE" 2>/dev/null || true)"
    printf "DAEMON_PID=%s\n" "$daemon_pid"
    if kill -0 "$daemon_pid" >/dev/null 2>&1; then
      printf "DAEMON_STATUS=up\n"
    else
      printf "DAEMON_STATUS=down\n"
    fi
  else
    if ps w 2>/dev/null | grep -F "/usr/bin/warren-remote-agent daemon" >/dev/null 2>&1; then
      printf "DAEMON_STATUS=up\n"
    else
      printf "DAEMON_STATUS=unknown\n"
    fi
  fi
  if tunnel_running; then
    tunnel_pid="$(current_pid 2>/dev/null || true)"
    if ! pid_is_alive "$tunnel_pid"; then
      tunnel_pid=""
    fi
    if [ -z "$tunnel_pid" ]; then
      tunnel_pid="$(discover_tunnel_pid "$(sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)" "$(sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)")"
      if [ -n "$tunnel_pid" ]; then
        printf "%s\n" "$tunnel_pid" > "$PID_FILE" 2>/dev/null || true
      fi
    fi
    printf "TUNNEL_STATUS=up\n"
    sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1 | sed 's/^/TUNNEL_SSH_PORT=/'
    sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1 | sed 's/^/TUNNEL_LUCI_PORT=/'
    if [ -z "$tunnel_pid" ]; then
      tunnel_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      pid_is_alive "$tunnel_pid" || tunnel_pid=""
    fi
    printf "TUNNEL_PID=%s\n" "$tunnel_pid"
  else
    printf "TUNNEL_STATUS=down\n"
  fi
}

poll_once() {
  load_config || {
    log "config unavailable: $CONFIG"
    return 1
  }
  ensure_state_dir

  response=""
  last_error=""
  chosen_endpoint=""
  chosen_action=""
  for endpoint in $(endpoint_candidates); do
    if tmp_response="$(helper_call "$endpoint" poll "$REMOTE_ADMIN_ROUTER_ID" "$REMOTE_ADMIN_ROUTER_NAME" "$(sha256_text "$(cat "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" 2>/dev/null || printf "")")" 2>/dev/null)"; then
      tmp_action="$(printf "%s\n" "$tmp_response" | sed -n 's/^ACTION=//p' | head -n1)"
      if [ -z "$response" ]; then
        response="$tmp_response"
        chosen_endpoint="$endpoint"
        chosen_action="$tmp_action"
      fi
      case "$tmp_action" in
        OPEN|CLOSE)
          response="$tmp_response"
          chosen_endpoint="$endpoint"
          chosen_action="$tmp_action"
          break
          ;;
      esac
    fi
    last_error="$endpoint"
  done

  [ -n "$response" ] || {
    log "no responsive endpoint for $REMOTE_ADMIN_ROUTER_ID ${last_error:+(last tried: $last_error)}"
    return 1
  }

  action="${chosen_action:-$(printf "%s\n" "$response" | sed -n 's/^ACTION=//p' | head -n1)}"
  tunnel_ssh_port="$(printf "%s\n" "$response" | sed -n 's/^TUNNEL_SSH_PORT=//p' | head -n1)"
  tunnel_luci_port="$(printf "%s\n" "$response" | sed -n 's/^TUNNEL_LUCI_PORT=//p' | head -n1)"
  request_id="$(printf "%s\n" "$response" | sed -n 's/^REQUEST_ID=//p' | head -n1)"
  [ -n "$chosen_endpoint" ] || return 1

  case "$action" in
    OPEN)
      [ -n "$tunnel_ssh_port" ] || return 1
      [ -n "$tunnel_luci_port" ] || return 1
      endpoint_host="${chosen_endpoint%:*}"
      endpoint_port="${chosen_endpoint##*:}"
      case "$chosen_endpoint" in
        *:*)
          if ! printf "%s" "$endpoint_port" | grep -Eq '^[0-9]+$'; then
            endpoint_port="22"
          fi
          ;;
        *)
          endpoint_port="22"
          ;;
      esac
      start_tunnel "$endpoint_host" "$endpoint_port" "$tunnel_ssh_port" "$tunnel_luci_port" || return 1
      for endpoint in $(endpoint_candidates); do
        helper_call "$endpoint" tunnel-up "$REMOTE_ADMIN_ROUTER_ID" "$request_id" "$tunnel_ssh_port" "$tunnel_luci_port" >/dev/null 2>&1 && break || true
      done
      write_last_poll "OPEN" "$chosen_endpoint" "tunnel-up" "$request_id"
      ;;
    CLOSE)
      stop_tunnel
      for endpoint in $(endpoint_candidates); do
        helper_call "$endpoint" tunnel-down "$REMOTE_ADMIN_ROUTER_ID" "$request_id" >/dev/null 2>&1 && break || true
      done
      write_last_poll "CLOSE" "$chosen_endpoint" "tunnel-down" "$request_id"
      ;;
    NONE|"")
      if ! tunnel_running; then
        rm -f "$PID_FILE" "$CURRENT_PORTS_FILE" >/dev/null 2>&1 || true
      fi
      write_last_poll "NONE" "$chosen_endpoint" "idle" "$request_id"
      ;;
  esac
}

daemon_loop() {
  load_config || exit 1
  ensure_state_dir
  printf "%s\n" "$$" > "$DAEMON_PID_FILE"
  trap 'rm -f "$DAEMON_PID_FILE" >/dev/null 2>&1 || true' EXIT INT TERM
  log "daemon starting for ${REMOTE_ADMIN_ROUTER_ID:-unknown}"
  while :; do
    poll_once || true
    sleep "${REMOTE_ADMIN_POLL_INTERVAL:-30}"
  done
}

case "${1:-daemon}" in
  daemon) daemon_loop ;;
  poll) poll_once ;;
  status) load_config || true; report_status ;;
  start)
    shift || true
    load_config || exit 1
    ensure_state_dir
    start_tunnel "${1:-${REMOTE_ADMIN_LOCAL_SSH_PORT:-2201}}" "${2:-${REMOTE_ADMIN_LOCAL_LUCI_PORT:-8081}}"
    ;;
  stop)
    stop_tunnel
    ;;
  *)
    echo "Usage: warren-remote-agent {daemon|poll|status|start|stop}" >&2
    exit 2
    ;;
esac
EOF
}

remote_admin_write_router_init() {
  target="$1"
  cat > "$target" <<'EOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=10

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/warren-remote-agent daemon
  procd_set_param respawn 3600 5 0
  procd_close_instance
}

stop_service() {
  /usr/bin/warren-remote-agent stop >/dev/null 2>&1 || true
}
EOF
}

remote_admin_write_vps_helper() {
  target="$1"
  cat > "$target" <<'EOF'
#!/bin/sh
set -eu

BASE_DIR="${WARREN_REMOTE_ADMIN_BASE_DIR:-/var/lib/warren-remote}"
ROUTERS_DIR="${BASE_DIR}/routers"
REQUESTS_DIR="${BASE_DIR}/requests"
NEXT_PORT_FILE="${BASE_DIR}/next-port"
CRON_FILE="${WARREN_REMOTE_ADMIN_CRON_FILE:-/etc/cron.d/warren-remote}"
DEFAULT_PORT_BASE="${WARREN_REMOTE_ADMIN_PORT_BASE:-22000}"

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

ensure_dirs() {
  mkdir -p "$ROUTERS_DIR" "$REQUESTS_DIR" >/dev/null 2>&1
  if [ ! -f "$NEXT_PORT_FILE" ]; then
    printf "%s\n" "$DEFAULT_PORT_BASE" > "$NEXT_PORT_FILE"
  fi
}

sanitize_id() {
  printf "%s" "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

safe_text() {
  printf "%s" "$1" | tr ' ' '_'
}

router_file() {
  printf "%s/%s.env" "$ROUTERS_DIR" "$(sanitize_id "$1")"
}

request_file() {
  printf "%s/%s.env" "$REQUESTS_DIR" "$(sanitize_id "$1")"
}

read_value() {
  file="$1"
  key="$2"
  [ -r "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n1
}

write_env() {
  file="$1"
  shift
  tmp="${file}.tmp.$$"
  : > "$tmp"
  for pair in "$@"; do
    printf "%s\n" "$pair" >> "$tmp"
  done
  mv "$tmp" "$file"
}

load_router() {
  file="$(router_file "$1")"
  if [ -r "$file" ]; then
    # shellcheck disable=SC1090
    . "$file"
  fi
}

allocate_ports() {
  next="$(cat "$NEXT_PORT_FILE" 2>/dev/null || printf "%s" "$DEFAULT_PORT_BASE")"
  case "$next" in
    ''|*[!0-9]*) next="$DEFAULT_PORT_BASE" ;;
  esac
  ssh_port="$next"
  luci_port=$((next + 1))
  printf "%s\n" $((next + 10)) > "$NEXT_PORT_FILE"
  printf "%s %s\n" "$ssh_port" "$luci_port"
}

router_seen() {
  router_id="$1"
  router_name="${2:-$1}"
  pubkey="${3:-}"
  source_host="${4:-}"
  last_seen="$(now_epoch)"
  file="$(router_file "$router_id")"
  pubkey_hash="$pubkey"
  if [ -n "$pubkey_hash" ] && ! printf "%s" "$pubkey_hash" | grep -Eq '^[A-Fa-f0-9]{64}$'; then
    pubkey_hash="$(hash_text "$pubkey_hash")"
  fi
  mkdir -p "$ROUTERS_DIR" >/dev/null 2>&1
  {
    printf "ROUTER_ID=%s\n" "$router_id"
    printf "ROUTER_NAME=%s\n" "$(safe_text "$router_name")"
    printf "ROUTER_PUBLIC_KEY_SHA256=%s\n" "$pubkey_hash"
    printf "ROUTER_SOURCE=%s\n" "$(safe_text "$source_host")"
    printf "LAST_SEEN=%s\n" "$last_seen"
    printf "LAST_HEARTBEAT=%s\n" "$last_seen"
    printf "TUNNEL_STATUS=%s\n" "${TUNNEL_STATUS:-down}"
    printf "TUNNEL_SSH_PORT=%s\n" "${TUNNEL_SSH_PORT:-}"
    printf "TUNNEL_LUCI_PORT=%s\n" "${TUNNEL_LUCI_PORT:-}"
    printf "REQUEST_STATE=%s\n" "${REQUEST_STATE:-none}"
    printf "REQUEST_AT=%s\n" "${REQUEST_AT:-}"
    printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"
    printf "REQUEST_ID=%s\n" "${REQUEST_ID:-}"
    printf "REQUEST_EXPIRES=%s\n" "${REQUEST_EXPIRES:-}"
  } > "$file"
}

request_create() {
  router_id="$1"
  ttl="${2:-900}"
  router_name="${3:-$router_id}"
  ensure_dirs
  load_router "$router_id"
  ports="$(allocate_ports)"
  tunnel_ssh_port="$(printf "%s" "$ports" | awk '{print $1}')"
  tunnel_luci_port="$(printf "%s" "$ports" | awk '{print $2}')"
  request_id="$(date +%Y%m%d%H%M%S)-$(sanitize_id "$router_id")"
  request_at="$(now_epoch)"
  case "$ttl" in
    ''|*[!0-9]*) ttl=900 ;;
  esac
  if [ "$ttl" -le 0 ]; then
    request_expires=0
  else
    request_expires=$((request_at + ttl))
  fi
  request_file_path="$(request_file "$router_id")"
  write_env "$request_file_path" \
    "ROUTER_ID=${router_id}" \
    "ROUTER_NAME=$(safe_text "$router_name")" \
    "REQUEST_ID=${request_id}" \
    "REQUEST_STATE=requested" \
    "REQUEST_AT=${request_at}" \
    "REQUEST_TTL=${ttl}" \
    "REQUEST_EXPIRES=${request_expires}" \
    "TUNNEL_SSH_PORT=${tunnel_ssh_port}" \
    "TUNNEL_LUCI_PORT=${tunnel_luci_port}" \
    "REQUESTED_BY=ssh"
  router_seen "$router_id" "$router_name" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${SSH_CONNECTION:-}"
  printf "ACTION=OPEN\n"
  printf "REQUEST_ID=%s\n" "$request_id"
  printf "REQUEST_TTL=%s\n" "$ttl"
  printf "TUNNEL_SSH_PORT=%s\n" "$tunnel_ssh_port"
  printf "TUNNEL_LUCI_PORT=%s\n" "$tunnel_luci_port"
}

request_close() {
  router_id="$1"
  file="$(request_file "$router_id")"
  [ -e "$file" ] && rm -f "$file"
  load_router "$router_id"
  router_seen "$router_id" "${ROUTER_NAME:-$router_id}" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${ROUTER_SOURCE:-}"
  file="$(router_file "$router_id")"
  {
    printf "ROUTER_ID=%s\n" "$router_id"
    printf "REQUEST_STATE=closed\n"
    printf "REQUEST_AT=\n"
    printf "REQUEST_TTL=\n"
    printf "REQUEST_ID=\n"
    printf "REQUEST_EXPIRES=\n"
  } >> "$file"
}

request_state() {
  router_id="$1"
  file="$(request_file "$router_id")"
  [ -r "$file" ] || return 1
  # shellcheck disable=SC1090
  . "$file"
  now="$(now_epoch)"
  case "${REQUEST_EXPIRES:-0}" in
    0)
      return 0
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$now" -gt "$REQUEST_EXPIRES" ]; then
    rm -f "$file" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

router_request_snapshot() {
  router_id="$1"
  file="$(request_file "$router_id")"
  if request_state "$router_id"; then
    : 
  fi
  [ -r "$file" ] || return 1
  # shellcheck disable=SC1090
  . "$file"
  printf "REQUEST_STATE=%s\n" "${REQUEST_STATE:-requested}"
  printf "REQUEST_ID=%s\n" "${REQUEST_ID:-}"
  printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"
  printf "REQUEST_EXPIRES=%s\n" "${REQUEST_EXPIRES:-}"
  printf "TUNNEL_SSH_PORT=%s\n" "${TUNNEL_SSH_PORT:-}"
  printf "TUNNEL_LUCI_PORT=%s\n" "${TUNNEL_LUCI_PORT:-}"
}

poll_router() {
  router_id="$1"
  router_name="${2:-$1}"
  pubkey="${3:-}"
  source_host="${4:-${SSH_CONNECTION:-}}"
  ensure_dirs
  request_file_path="$(request_file "$router_id")"
  request_active=0
  if request_state "$router_id"; then
    request_active=1
  fi

  if [ "$request_active" -eq 1 ]; then
    # shellcheck disable=SC1090
    . "$request_file_path"
    router_seen "$router_id" "$router_name" "$pubkey" "$source_host"
    {
      printf "ACTION=OPEN\n"
      printf "REQUEST_ID=%s\n" "${REQUEST_ID:-}"
      printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"
      printf "TUNNEL_SSH_PORT=%s\n" "${TUNNEL_SSH_PORT:-}"
      printf "TUNNEL_LUCI_PORT=%s\n" "${TUNNEL_LUCI_PORT:-}"
    }
    return 0
  fi

  router_seen "$router_id" "$router_name" "$pubkey" "$source_host"
  printf "ACTION=NONE\n"
}

router_tunnel_up() {
  router_id="$1"
  request_id="${2:-}"
  tunnel_ssh_port="${3:-}"
  tunnel_luci_port="${4:-}"
  file="$(router_file "$router_id")"
  ensure_dirs
  load_router "$router_id"
  {
    printf "ROUTER_ID=%s\n" "$router_id"
    printf "ROUTER_NAME=%s\n" "$(safe_text "${ROUTER_NAME:-$router_id}")"
    printf "LAST_SEEN=%s\n" "$(now_epoch)"
    printf "LAST_HEARTBEAT=%s\n" "$(now_epoch)"
    printf "TUNNEL_STATUS=up\n"
    printf "TUNNEL_SSH_PORT=%s\n" "$tunnel_ssh_port"
    printf "TUNNEL_LUCI_PORT=%s\n" "$tunnel_luci_port"
    printf "REQUEST_STATE=%s\n" "requested"
    printf "REQUEST_ID=%s\n" "$request_id"
    printf "REQUEST_AT=%s\n" "${REQUEST_AT:-}"
    printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"
    printf "REQUEST_EXPIRES=%s\n" "${REQUEST_EXPIRES:-}"
    printf "ROUTER_PUBLIC_KEY_SHA256=%s\n" "${ROUTER_PUBLIC_KEY_SHA256:-}"
    printf "ROUTER_SOURCE=%s\n" "${ROUTER_SOURCE:-}"
  } > "$file"
  printf "TUNNEL_STATUS=up\n"
}

router_tunnel_down() {
  router_id="$1"
  request_id="${2:-}"
  ensure_dirs
  load_router "$router_id"
  file="$(router_file "$router_id")"
  {
    printf "ROUTER_ID=%s\n" "$router_id"
    printf "ROUTER_NAME=%s\n" "$(safe_text "${ROUTER_NAME:-$router_id}")"
    printf "LAST_SEEN=%s\n" "$(now_epoch)"
    printf "LAST_HEARTBEAT=%s\n" "$(now_epoch)"
    printf "TUNNEL_STATUS=down\n"
    printf "TUNNEL_SSH_PORT=%s\n" ""
    printf "TUNNEL_LUCI_PORT=%s\n" ""
    printf "REQUEST_STATE=%s\n" "closed"
    printf "REQUEST_ID=%s\n" "$request_id"
    printf "REQUEST_AT=%s\n" "${REQUEST_AT:-}"
    printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"
    printf "REQUEST_EXPIRES=%s\n" "${REQUEST_EXPIRES:-}"
    printf "ROUTER_PUBLIC_KEY_SHA256=%s\n" "${ROUTER_PUBLIC_KEY_SHA256:-}"
    printf "ROUTER_SOURCE=%s\n" "${ROUTER_SOURCE:-}"
  } > "$file"
  printf "TUNNEL_STATUS=down\n"
}

router_status() {
  router_id="$1"
  file="$(router_file "$router_id")"
  [ -r "$file" ] || return 1
  cat "$file"
  printf "REQUEST_ACTIVE=%s\n" "$(request_state "$router_id" && printf yes || printf no)"
  if request_state "$router_id"; then
    router_request_snapshot "$router_id" || true
  fi
}

router_list() {
  ensure_dirs
  printf "ROUTER_ID|ROUTER_NAME|LAST_SEEN|REQUEST_STATE|TUNNEL_STATUS|SSH_PORT|LUCI_PORT\n"
  for file in "$ROUTERS_DIR"/*.env; do
    [ -r "$file" ] || continue
    # shellcheck disable=SC1090
    . "$file"
    request_status="none"
    if request_state "${ROUTER_ID:-}"; then
      request_status="requested"
    fi
    printf "%s|%s|%s|%s|%s|%s|%s\n" \
      "${ROUTER_ID:-}" \
      "${ROUTER_NAME:-}" \
      "${LAST_SEEN:-}" \
      "$request_status" \
      "${TUNNEL_STATUS:-down}" \
      "${TUNNEL_SSH_PORT:-}" \
      "${TUNNEL_LUCI_PORT:-}"
  done
}

cleanup() {
  ensure_dirs
  now="$(now_epoch)"
  for file in "$REQUESTS_DIR"/*.env; do
    [ -r "$file" ] || continue
    # shellcheck disable=SC1090
    . "$file"
    case "${REQUEST_EXPIRES:-0}" in
      0) continue ;;
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$now" -gt "$REQUEST_EXPIRES" ]; then
      rm -f "$file" >/dev/null 2>&1 || true
    fi
  done
}

install_cron() {
  {
    printf "*/5 * * * * root /usr/local/bin/warren-remote cleanup >/dev/null 2>&1\n"
  } >/etc/cron.d/warren-remote
  chmod 644 /etc/cron.d/warren-remote 2>/dev/null || true
}

cmd="${1:-}"
shift || true

case "$cmd" in
  init)
    ensure_dirs
    install_cron
    ;;
  list)
    router_list
    ;;
  request)
    ensure_dirs
    router_id="${1:-}"
    ttl="${2:-900}"
    router_name="${3:-$router_id}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    request_create "$router_id" "$ttl" "$router_name"
    ;;
  close)
    router_id="${1:-}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    request_close "$router_id"
    ;;
  status)
    router_id="${1:-}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    router_status "$router_id"
    ;;
  poll)
    router_id="${1:-}"
    router_name="${2:-$router_id}"
    pubkey="${3:-}"
    source_host="${4:-${SSH_CONNECTION:-}}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    poll_router "$router_id" "$router_name" "$pubkey" "$source_host"
    ;;
  tunnel-up)
    router_id="${1:-}"
    request_id="${2:-}"
    tunnel_ssh_port="${3:-}"
    tunnel_luci_port="${4:-}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    router_tunnel_up "$router_id" "$request_id" "$tunnel_ssh_port" "$tunnel_luci_port"
    ;;
  tunnel-down)
    router_id="${1:-}"
    request_id="${2:-}"
    [ -n "$router_id" ] || {
      echo "missing router_id" >&2
      exit 2
    }
    router_tunnel_down "$router_id" "$request_id"
    ;;
  cleanup)
    cleanup
    ;;
  *)
    echo "Usage: warren-remote {init|list|request|close|status|poll|tunnel-up|tunnel-down|cleanup}" >&2
    exit 2
    ;;
esac
EOF
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
  remote_admin_save_config
  remote_admin_install_router_agent || fail "Не удалось установить router-side Remote Admin"
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
