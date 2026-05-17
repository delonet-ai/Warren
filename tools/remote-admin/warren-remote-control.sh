#!/bin/sh
set -eu

CONFIG="${WARREN_REMOTE_ADMIN_CONFIG:-${HOME}/.config/warren/remote-admin.conf}"
LOCAL_SSH_PORT="${REMOTE_ADMIN_LOCAL_SSH_PORT:-2201}"
LOCAL_LUCI_PORT="${REMOTE_ADMIN_LOCAL_LUCI_PORT:-8081}"
WAIT_SECONDS="${REMOTE_ADMIN_WAIT_SECONDS:-180}"
REQUEST_TTL="${REMOTE_ADMIN_REQUEST_TTL:-900}"

load_config() {
  [ -r "$CONFIG" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG"
}

require_value() {
  name="$1"
  value="$2"
  [ -n "$value" ] || {
    echo "missing $name" >&2
    exit 2
  }
}

vps_ssh_base() {
  if [ -n "${REMOTE_ADMIN_VPS_KEY_PATH:-}" ]; then
    ssh \
      -p "${REMOTE_ADMIN_VPS_PORT:-22}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -i "$REMOTE_ADMIN_VPS_KEY_PATH" \
      "${REMOTE_ADMIN_VPS_USER:-root}@${REMOTE_ADMIN_VPS_HOST}" \
      "$@"
  else
    ssh \
      -p "${REMOTE_ADMIN_VPS_PORT:-22}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${REMOTE_ADMIN_VPS_USER:-root}@${REMOTE_ADMIN_VPS_HOST}" \
      "$@"
  fi
}

vps_remote() {
  vps_ssh_base "warren-remote $*"
}

show_usage() {
  cat <<'EOF'
Usage:
  warren-remote-control.sh list
  warren-remote-control.sh request <router-id> [ttl]
  warren-remote-control.sh status <router-id>
  warren-remote-control.sh close <router-id>
  warren-remote-control.sh connect <router-id> [ttl]
EOF
}

wait_for_ready() {
  router_id="$1"
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$WAIT_SECONDS" ]; then
      break
    fi
    status="$(vps_remote "status $router_id" 2>/dev/null || true)"
    tunnel_status="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_STATUS=//p' | head -n1)"
    ssh_port="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_SSH_PORT=//p' | head -n1)"
    luci_port="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_LUCI_PORT=//p' | head -n1)"
    request_state="$(printf "%s\n" "$status" | sed -n 's/^REQUEST_STATE=//p' | head -n1)"
    if [ "$tunnel_status" = "up" ] && [ -n "$ssh_port" ] && [ -n "$luci_port" ]; then
      printf "%s %s %s\n" "$request_state" "$ssh_port" "$luci_port"
      return 0
    fi
    sleep 2
  done
  return 1
}

open_browser() {
  url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

cmd="${1:-}"
shift || true

load_config
require_value REMOTE_ADMIN_VPS_HOST "${REMOTE_ADMIN_VPS_HOST:-}"

case "$cmd" in
  list)
    vps_remote list
    ;;
  request)
    router_id="${1:-${REMOTE_ADMIN_DEFAULT_ROUTER_ID:-}}"
    ttl="${2:-$REQUEST_TTL}"
    require_value router_id "$router_id"
    vps_remote "request $router_id $ttl"
    ;;
  status)
    router_id="${1:-${REMOTE_ADMIN_DEFAULT_ROUTER_ID:-}}"
    require_value router_id "$router_id"
    vps_remote "status $router_id"
    ;;
  close)
    router_id="${1:-${REMOTE_ADMIN_DEFAULT_ROUTER_ID:-}}"
    require_value router_id "$router_id"
    vps_remote "close $router_id"
    ;;
  connect)
    router_id="${1:-${REMOTE_ADMIN_DEFAULT_ROUTER_ID:-}}"
    ttl="${2:-$REQUEST_TTL}"
    require_value router_id "$router_id"
    echo "Requesting router $router_id for $ttl seconds..."
    vps_remote "request $router_id $ttl"
    echo "Waiting for router tunnel..."
    ready="$(wait_for_ready "$router_id")" || {
      echo "Router did not become ready in time." >&2
      exit 1
    }
    request_state="$(printf "%s\n" "$ready" | awk '{print $1}')"
    ssh_port="$(printf "%s\n" "$ready" | awk '{print $2}')"
    luci_port="$(printf "%s\n" "$ready" | awk '{print $3}')"
    echo "Tunnel ready: ssh=$ssh_port luci=$luci_port request=$request_state"
    echo "Opening LuCI at http://127.0.0.1:${LOCAL_LUCI_PORT}"
    open_browser "http://127.0.0.1:${LOCAL_LUCI_PORT}"
    if [ -n "${REMOTE_ADMIN_VPS_KEY_PATH:-}" ]; then
      exec ssh \
        -N \
        -L "${LOCAL_SSH_PORT}:127.0.0.1:${ssh_port}" \
        -L "${LOCAL_LUCI_PORT}:127.0.0.1:${luci_port}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=20 \
        -o ServerAliveCountMax=3 \
        -i "$REMOTE_ADMIN_VPS_KEY_PATH" \
        -p "${REMOTE_ADMIN_VPS_PORT:-22}" \
        "${REMOTE_ADMIN_VPS_USER:-root}@${REMOTE_ADMIN_VPS_HOST}"
    else
      exec ssh \
        -N \
        -L "${LOCAL_SSH_PORT}:127.0.0.1:${ssh_port}" \
        -L "${LOCAL_LUCI_PORT}:127.0.0.1:${luci_port}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=20 \
        -o ServerAliveCountMax=3 \
        -p "${REMOTE_ADMIN_VPS_PORT:-22}" \
        "${REMOTE_ADMIN_VPS_USER:-root}@${REMOTE_ADMIN_VPS_HOST}"
    fi
    ;;
  *)
    show_usage >&2
    exit 2
    ;;
esac
