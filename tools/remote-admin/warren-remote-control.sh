#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REMOTE_HOME="${WARREN_REMOTE_ADMIN_HOME:-${HOME}/.config/warren/remote-admin}"
VPS_DIR="${REMOTE_HOME}/vps.d"
LEGACY_CONFIG="${WARREN_REMOTE_ADMIN_CONFIG:-${REMOTE_HOME}/remote-admin.conf}"
DEFAULT_HELPER_PATH="/usr/local/bin/warren-remote"

mkdir -p "$VPS_DIR"

say() { printf "%s\n" "$*"; }
err() { printf "%s\n" "$*" >&2; }
die() { err "FAIL: $*"; exit 1; }

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

safe_name() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

profile_path() {
  safe_name "$1" || die "Bad VPS name: $1"
  printf "%s/%s.conf" "$VPS_DIR" "$1"
}

chmod_private() {
  chmod 600 "$1" 2>/dev/null || true
}

write_profile() {
  path="$(profile_path "$VPS_NAME")"
  {
    printf "VPS_NAME=%s\n" "$(quote_sh "$VPS_NAME")"
    printf "VPS_HOST=%s\n" "$(quote_sh "$VPS_HOST")"
    printf "VPS_SSH_PORT=%s\n" "$(quote_sh "${VPS_SSH_PORT:-22}")"
    printf "VPS_SSH_USER=%s\n" "$(quote_sh "${VPS_SSH_USER:-root}")"
    printf "VPS_SSH_KEY_PATH=%s\n" "$(quote_sh "${VPS_SSH_KEY_PATH:-}")"
    printf "VPS_ROOT_PASSWORD=%s\n" "$(quote_sh "${VPS_ROOT_PASSWORD:-}")"
    printf "REMOTE_HELPER_PATH=%s\n" "$(quote_sh "${REMOTE_HELPER_PATH:-$DEFAULT_HELPER_PATH}")"
    printf "DEFAULT_ROUTER_ID=%s\n" "$(quote_sh "${DEFAULT_ROUTER_ID:-}")"
    printf "LOCAL_SSH_PORT=%s\n" "$(quote_sh "${LOCAL_SSH_PORT:-2201}")"
    printf "LOCAL_LUCI_PORT=%s\n" "$(quote_sh "${LOCAL_LUCI_PORT:-8081}")"
    printf "REQUEST_TTL=%s\n" "$(quote_sh "${REQUEST_TTL:-900}")"
    printf "WAIT_SECONDS=%s\n" "$(quote_sh "${WAIT_SECONDS:-180}")"
  } > "$path"
  chmod_private "$path"
  say "Saved VPS profile: $path"
}

load_profile() {
  name="${1:-}"
  if [ -z "$name" ]; then
    name="$(first_profile_name)"
  fi
  [ -n "$name" ] || die "No VPS profile found. Run: $0 vps add"
  path="$(profile_path "$name")"
  [ -r "$path" ] || die "VPS profile not found: $name"
  # shellcheck disable=SC1090
  . "$path"
  VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
  VPS_SSH_USER="${VPS_SSH_USER:-root}"
  REMOTE_HELPER_PATH="${REMOTE_HELPER_PATH:-$DEFAULT_HELPER_PATH}"
  LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-2201}"
  LOCAL_LUCI_PORT="${LOCAL_LUCI_PORT:-8081}"
  REQUEST_TTL="${REQUEST_TTL:-900}"
  WAIT_SECONDS="${WAIT_SECONDS:-180}"
}

first_profile_name() {
  for file in "$VPS_DIR"/*.conf; do
    [ -r "$file" ] || continue
    basename "$file" .conf
    return 0
  done
  return 0
}

prompt() {
  label="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$label" "$default" >&2
  else
    printf "%s: " "$label" >&2
  fi
  read -r value
  [ -n "$value" ] || value="$default"
  printf "%s" "$value"
}

ssh_cmd() {
  remote_cmd="$1"
  if [ -n "${VPS_SSH_KEY_PATH:-}" ]; then
    ssh -p "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -i "$VPS_SSH_KEY_PATH" \
      "${VPS_SSH_USER}@${VPS_HOST}" "$remote_cmd"
  elif [ -n "${VPS_ROOT_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$VPS_ROOT_PASSWORD" ssh -p "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${VPS_SSH_USER}@${VPS_HOST}" "$remote_cmd"
  else
    ssh -p "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${VPS_SSH_USER}@${VPS_HOST}" "$remote_cmd"
  fi
}

scp_to_vps() {
  src="$1"
  dst="$2"
  if [ -n "${VPS_SSH_KEY_PATH:-}" ]; then
    scp -P "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -i "$VPS_SSH_KEY_PATH" "$src" "${VPS_SSH_USER}@${VPS_HOST}:$dst"
  elif [ -n "${VPS_ROOT_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$VPS_ROOT_PASSWORD" scp -P "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "$src" "${VPS_SSH_USER}@${VPS_HOST}:$dst"
  else
    scp -P "$VPS_SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "$src" "${VPS_SSH_USER}@${VPS_HOST}:$dst"
  fi
}

remote_helper() {
  ssh_cmd "$(quote_sh "$REMOTE_HELPER_PATH") $*"
}

show_usage() {
  cat <<'EOF'
Usage:
  warren-remote-control.sh
  warren-remote-control.sh vps add|edit|remove|list|check|bootstrap|install-helper [--vps name]
  warren-remote-control.sh routers --vps name
  warren-remote-control.sh request --vps name --router router_id [--ttl seconds]
  warren-remote-control.sh connect --vps name --router router_id [--no-timeout]
  warren-remote-control.sh status --vps name --router router_id
  warren-remote-control.sh close --vps name --router router_id
  warren-remote-control.sh router install-agent --vps name --host router_host [--user root] [--port 22] [--key path]

Legacy aliases:
  setup | config | list | request <router-id> | status <router-id> | close <router-id> | connect <router-id>
EOF
}

parse_common_flags() {
  VPS_SELECT=""
  ROUTER_ID=""
  ROUTER_HOST=""
  ROUTER_USER="root"
  ROUTER_PORT="22"
  ROUTER_KEY_PATH=""
  CONNECT_NO_TIMEOUT="0"
  REQUEST_TTL_OVERRIDE=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vps) VPS_SELECT="${2:-}"; shift 2 ;;
      --router) ROUTER_ID="${2:-}"; shift 2 ;;
      --ttl) REQUEST_TTL_OVERRIDE="${2:-}"; shift 2 ;;
      --host) ROUTER_HOST="${2:-}"; shift 2 ;;
      --user) ROUTER_USER="${2:-root}"; shift 2 ;;
      --port) ROUTER_PORT="${2:-22}"; shift 2 ;;
      --key) ROUTER_KEY_PATH="${2:-}"; shift 2 ;;
      --no-timeout) CONNECT_NO_TIMEOUT="1"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

cmd_vps_add() {
  VPS_NAME="$(prompt "Profile name" "${VPS_NAME:-}")"
  safe_name "$VPS_NAME" || die "Profile name may contain only A-Z a-z 0-9 . _ -"
  VPS_HOST="$(prompt "VPS host/IP" "${VPS_HOST:-}")"
  [ -n "$VPS_HOST" ] || die "VPS host is required"
  VPS_SSH_PORT="$(prompt "SSH port" "${VPS_SSH_PORT:-22}")"
  VPS_SSH_USER="$(prompt "SSH user" "${VPS_SSH_USER:-root}")"
  VPS_SSH_KEY_PATH="$(prompt "SSH key path" "${VPS_SSH_KEY_PATH:-}")"
  if [ -z "$VPS_SSH_KEY_PATH" ]; then
    VPS_ROOT_PASSWORD="$(prompt "VPS password (stored in 0600 profile)" "${VPS_ROOT_PASSWORD:-}")"
  else
    VPS_ROOT_PASSWORD="${VPS_ROOT_PASSWORD:-}"
  fi
  REMOTE_HELPER_PATH="$(prompt "Remote helper path" "${REMOTE_HELPER_PATH:-$DEFAULT_HELPER_PATH}")"
  DEFAULT_ROUTER_ID="$(prompt "Default router id" "${DEFAULT_ROUTER_ID:-}")"
  LOCAL_SSH_PORT="$(prompt "Local SSH port" "${LOCAL_SSH_PORT:-2201}")"
  LOCAL_LUCI_PORT="$(prompt "Local LuCI port" "${LOCAL_LUCI_PORT:-8081}")"
  REQUEST_TTL="$(prompt "Request TTL seconds" "${REQUEST_TTL:-900}")"
  WAIT_SECONDS="$(prompt "Wait seconds" "${WAIT_SECONDS:-180}")"
  write_profile
}

cmd_vps_list() {
  found=0
  for file in "$VPS_DIR"/*.conf; do
    [ -r "$file" ] || continue
    found=1
    # shellcheck disable=SC1090
    . "$file"
    printf "%s\t%s:%s\t%s\tkey:%s\n" \
      "${VPS_NAME:-$(basename "$file" .conf)}" \
      "${VPS_HOST:-unknown}" \
      "${VPS_SSH_PORT:-22}" \
      "${VPS_SSH_USER:-root}" \
      "$( [ -n "${VPS_SSH_KEY_PATH:-}" ] && printf yes || printf no )"
  done
  [ "$found" -eq 1 ] || say "No VPS profiles in $VPS_DIR"
}

cmd_vps_edit() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  cmd_vps_add
}

cmd_vps_remove() {
  parse_common_flags "$@"
  [ -n "$VPS_SELECT" ] || VPS_SELECT="$(prompt "Profile name" "")"
  path="$(profile_path "$VPS_SELECT")"
  [ -e "$path" ] || die "Profile not found: $VPS_SELECT"
  rm -f "$path"
  say "Removed VPS profile: $VPS_SELECT"
}

cmd_vps_check() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  say "Checking SSH: ${VPS_SSH_USER}@${VPS_HOST}:${VPS_SSH_PORT}"
  ssh_cmd "sh -lc 'printf \"__WARREN_SSH_OK__\\n\"; printf \"OS=\"; (. /etc/os-release 2>/dev/null && printf \"%s:%s\" \"\${ID:-unknown}\" \"\${VERSION_ID:-unknown}\") || uname -s; printf \"\\n\"; if test -x $(quote_sh "$REMOTE_HELPER_PATH"); then printf \"__WARREN_REMOTE_HELPER_OK__\\n\"; $(quote_sh "$REMOTE_HELPER_PATH") list >/dev/null && printf \"__WARREN_REMOTE_HELPER_LIST_OK__\\n\" || printf \"__WARREN_REMOTE_HELPER_LIST_FAIL__\\n\"; else printf \"__WARREN_REMOTE_HELPER_MISSING__\\n\"; fi'"
}

payload_file() {
  name="$1"
  path="$SCRIPT_DIR/../../payload/$name"
  [ -r "$path" ] || die "Warren payload not found: $path (run from a Warren checkout)"
  printf "%s" "$path"
}

write_vps_helper_file() {
  cp "$(payload_file warren-remote)" "$1"
  chmod 700 "$1"
}

write_router_agent_file() {
  cp "$(payload_file warren-remote-agent)" "$1"
}

write_router_init_file() {
  cp "$(payload_file warren-remote-admin.init)" "$1"
  chmod 755 "$1"
}

cmd_vps_install_helper() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  if [ -z "${VPS_SSH_KEY_PATH:-}" ] && [ -n "${VPS_ROOT_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
    die "VPS profile uses password auth, but sshpass is not installed on this Mac. Add an SSH key path or install sshpass."
  fi
  tmp="${TMPDIR:-/tmp}/warren-remote-helper.$$"
  write_vps_helper_file "$tmp"
  say "Bootstrapping Remote Admin VPS components on ${VPS_HOST}..."
  ssh_cmd "sh -lc '
    set -eu
    if [ \"\$(id -u)\" != 0 ]; then
      command -v sudo >/dev/null 2>&1 || { echo sudo required; exit 1; }
      SUDO=sudo
    else
      SUDO=
    fi
    if [ -r /etc/os-release ]; then
      . /etc/os-release
      echo \"Detected OS: \${PRETTY_NAME:-\${ID:-unknown}}\"
    else
      echo \"Detected OS: \$(uname -s 2>/dev/null || echo unknown)\"
    fi
    if command -v apt-get >/dev/null 2>&1; then
      \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
      \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server cron coreutils ca-certificates
      \$SUDO systemctl enable --now cron >/dev/null 2>&1 || \$SUDO service cron start >/dev/null 2>&1 || true
      \$SUDO systemctl enable --now ssh >/dev/null 2>&1 || \$SUDO systemctl enable --now sshd >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      \$SUDO dnf install -y openssh-server cronie coreutils ca-certificates
      \$SUDO systemctl enable --now crond >/dev/null 2>&1 || true
      \$SUDO systemctl enable --now sshd >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      \$SUDO yum install -y openssh-server cronie coreutils ca-certificates
      \$SUDO systemctl enable --now crond >/dev/null 2>&1 || true
      \$SUDO systemctl enable --now sshd >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      \$SUDO apk add openssh-server coreutils ca-certificates
      \$SUDO rc-update add sshd default >/dev/null 2>&1 || true
      \$SUDO rc-service sshd start >/dev/null 2>&1 || true
    else
      echo \"No supported package manager found; continuing with existing shell/coreutils\"
    fi
    \$SUDO mkdir -p /usr/local/bin /var/lib/warren-remote
  '"
  scp_to_vps "$tmp" "/tmp/warren-remote.$$"
  ssh_cmd "sh -lc 'if [ \"\$(id -u)\" != 0 ]; then SUDO=sudo; else SUDO=; fi; \$SUDO mv /tmp/warren-remote.$$ $(quote_sh "$REMOTE_HELPER_PATH"); \$SUDO chmod 700 $(quote_sh "$REMOTE_HELPER_PATH"); \$SUDO $(quote_sh "$REMOTE_HELPER_PATH") init; $(quote_sh "$REMOTE_HELPER_PATH") list >/dev/null'"
  rm -f "$tmp"
  say "VPS helper ready: ${VPS_HOST}:${REMOTE_HELPER_PATH}"
}

cmd_routers() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  remote_helper list
}

wait_for_ready() {
  router_id="$1"
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    if [ "${WAIT_SECONDS:-0}" -gt 0 ]; then
      [ $((now - start)) -lt "$WAIT_SECONDS" ] || return 1
    fi
    status="$(remote_helper status "$router_id" 2>/dev/null || true)"
    tunnel_status="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_STATUS=//p' | head -n1)"
    ssh_port="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_SSH_PORT=//p' | head -n1)"
    luci_port="$(printf "%s\n" "$status" | sed -n 's/^TUNNEL_LUCI_PORT=//p' | head -n1)"
    request_state="$(printf "%s\n" "$status" | sed -n 's/^REQUEST_STATE=//p' | head -n1)"
    if [ "$tunnel_status" = "up" ] && [ -n "$ssh_port" ] && [ -n "$luci_port" ]; then
      printf "%s %s %s\n" "${request_state:-requested}" "$ssh_port" "$luci_port"
      return 0
    fi
    sleep 2
  done
}

open_browser() {
  url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

cmd_connect() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  [ -n "${ROUTER_ID:-}" ] || ROUTER_ID="${DEFAULT_ROUTER_ID:-}"
  [ -n "$ROUTER_ID" ] || ROUTER_ID="$(prompt "Router ID" "")"
  [ -n "$ROUTER_ID" ] || die "Router ID is required"
  ssh_cmd "test -x $(quote_sh "$REMOTE_HELPER_PATH")" || die "VPS helper missing. Run: $0 vps install-helper --vps ${VPS_NAME}"
  say "Requesting router $ROUTER_ID via VPS $VPS_NAME..."
  request_ttl="$REQUEST_TTL"
  if [ "${CONNECT_NO_TIMEOUT:-0}" = "1" ] || [ "${WAIT_SECONDS:-0}" -le 0 ]; then
    request_ttl=0
  fi
  remote_helper request "$ROUTER_ID" "$request_ttl" >/dev/null
  if [ "${CONNECT_NO_TIMEOUT:-0}" = "1" ] || [ "${WAIT_SECONDS:-0}" -le 0 ]; then
    WAIT_SECONDS=0
    say "Waiting for router tunnel without timeout..."
  else
    say "Waiting up to ${WAIT_SECONDS}s for router tunnel..."
  fi
  ready="$(wait_for_ready "$ROUTER_ID")" || die "Router did not become ready in time"
  ssh_port="$(printf "%s\n" "$ready" | awk '{print $2}')"
  luci_port="$(printf "%s\n" "$ready" | awk '{print $3}')"
  say "Tunnel ready. SSH localhost:${LOCAL_SSH_PORT}, LuCI localhost:${LOCAL_LUCI_PORT}"
  open_browser "http://127.0.0.1:${LOCAL_LUCI_PORT}"
  if [ -n "${VPS_SSH_KEY_PATH:-}" ]; then
    exec ssh -N -L "${LOCAL_SSH_PORT}:127.0.0.1:${ssh_port}" -L "${LOCAL_LUCI_PORT}:127.0.0.1:${luci_port}" \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
      -i "$VPS_SSH_KEY_PATH" -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}"
  elif [ -n "${VPS_ROOT_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    exec sshpass -p "$VPS_ROOT_PASSWORD" ssh -N -L "${LOCAL_SSH_PORT}:127.0.0.1:${ssh_port}" -L "${LOCAL_LUCI_PORT}:127.0.0.1:${luci_port}" \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
      -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}"
  else
    exec ssh -N -L "${LOCAL_SSH_PORT}:127.0.0.1:${ssh_port}" -L "${LOCAL_LUCI_PORT}:127.0.0.1:${luci_port}" \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
      -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}"
  fi
}

cmd_status() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  [ -n "${ROUTER_ID:-}" ] || ROUTER_ID="${DEFAULT_ROUTER_ID:-}"
  [ -n "$ROUTER_ID" ] || die "Router ID is required"
  remote_helper status "$ROUTER_ID"
}

cmd_request() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  [ -n "${ROUTER_ID:-}" ] || ROUTER_ID="${DEFAULT_ROUTER_ID:-}"
  [ -n "$ROUTER_ID" ] || die "Router ID is required"
  request_ttl="${REQUEST_TTL_OVERRIDE:-$REQUEST_TTL}"
  case "$request_ttl" in
    ""|*[!0-9]*) die "Request TTL must be a non-negative integer" ;;
  esac
  remote_helper request "$ROUTER_ID" "$request_ttl"
}

cmd_close() {
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  [ -n "${ROUTER_ID:-}" ] || ROUTER_ID="${DEFAULT_ROUTER_ID:-}"
  [ -n "$ROUTER_ID" ] || die "Router ID is required"
  remote_helper close "$ROUTER_ID"
}

router_ssh() {
  remote_cmd="$1"
  if [ -n "${ROUTER_KEY_PATH:-}" ]; then
    ssh -p "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$ROUTER_KEY_PATH" "${ROUTER_USER}@${ROUTER_HOST}" "$remote_cmd"
  else
    ssh -p "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${ROUTER_USER}@${ROUTER_HOST}" "$remote_cmd"
  fi
}

router_scp() {
  src="$1"
  dst="$2"
  if [ -n "${ROUTER_KEY_PATH:-}" ]; then
    scp -O -P "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$ROUTER_KEY_PATH" "$src" "${ROUTER_USER}@${ROUTER_HOST}:$dst"
  else
    scp -O -P "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "${ROUTER_USER}@${ROUTER_HOST}:$dst"
  fi
}

cmd_router_install_agent() {
  sub="${1:-}"; shift || true
  [ "$sub" = "install-agent" ] || die "Usage: router install-agent --vps name --host router_host"
  parse_common_flags "$@"
  load_profile "$VPS_SELECT"
  [ -n "$ROUTER_HOST" ] || die "--host router_host is required"
  tmp_agent="${TMPDIR:-/tmp}/warren-remote-agent.$$"
  tmp_init="${TMPDIR:-/tmp}/warren-remote-init.$$"
  tmp_conf="${TMPDIR:-/tmp}/warren-remote-conf.$$"
  write_router_agent_file "$tmp_agent"
  write_router_init_file "$tmp_init"
  router_id="$(printf "%s" "$ROUTER_HOST" | tr -cs 'A-Za-z0-9._-' '-')"
  endpoint="${VPS_HOST}:${VPS_SSH_PORT}"
  {
    printf "REMOTE_ADMIN_ROUTER_ID=%s\n" "$router_id"
    printf "REMOTE_ADMIN_ROUTER_NAME=%s\n" "$router_id"
    printf "REMOTE_ADMIN_ENDPOINTS=%s\n" "$endpoint"
    printf "REMOTE_ADMIN_VPS_USER=%s\n" "$VPS_SSH_USER"
    printf "REMOTE_ADMIN_POLL_INTERVAL=%s\n" "300"
    printf "REMOTE_ADMIN_REQUEST_TTL=%s\n" "$REQUEST_TTL"
    printf "REMOTE_ADMIN_LOCAL_SSH_PORT=%s\n" "2201"
    printf "REMOTE_ADMIN_LOCAL_LUCI_PORT=%s\n" "8081"
    printf "REMOTE_ADMIN_ROUTER_KEY_PATH=%s\n" "/etc/warren/remote-admin/router_ed25519"
    printf "REMOTE_ADMIN_ENABLED=1\n"
  } > "$tmp_conf"
  say "Installing router agent on ${ROUTER_HOST}..."
  router_ssh "mkdir -p /etc/warren/remote-admin /usr/bin /etc/init.d; command -v ssh-keygen >/dev/null 2>&1 || opkg update >/dev/null 2>&1 || true; [ -s /etc/warren/remote-admin/router_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /etc/warren/remote-admin/router_ed25519"
  router_scp "$tmp_agent" "/usr/bin/warren-remote-agent"
  router_scp "$tmp_init" "/etc/init.d/warren-remote-admin"
  router_scp "$tmp_conf" "/etc/warren/warren-remote-admin.conf"
  router_ssh "chmod 700 /usr/bin/warren-remote-agent; chmod 755 /etc/init.d/warren-remote-admin; /etc/init.d/warren-remote-admin enable; /etc/init.d/warren-remote-admin restart; /usr/bin/warren-remote-agent status"
  pubkey="$(router_ssh "cat /etc/warren/remote-admin/router_ed25519.pub")"
  [ -n "$pubkey" ] || die "Could not read router public key"
  # Pass pubkey via stdin to avoid quoting issues embedding single-quoted values in sh -lc '...'
  printf '%s\n' "$pubkey" | ssh_cmd 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; key="$(cat)"; grep -qxF "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
  rm -f "$tmp_agent" "$tmp_init" "$tmp_conf"
  say "Router agent installed. Router ID: $router_id"
}

legacy_load_or_profile() {
  if [ -r "$LEGACY_CONFIG" ] && [ ! -d "$VPS_DIR" ]; then
    # shellcheck disable=SC1090
    . "$LEGACY_CONFIG"
  fi
  load_profile "$(first_profile_name)"
}

cmd_setup() {
  if [ -r "${SCRIPT_DIR}/remote-admin.conf.example" ] && [ ! -r "$LEGACY_CONFIG" ]; then
    cp "${SCRIPT_DIR}/remote-admin.conf.example" "$LEGACY_CONFIG"
    chmod_private "$LEGACY_CONFIG"
  fi
  say "Remote Admin home: $REMOTE_HOME"
  say "Add a VPS profile with: $0 vps add"
}

tui_select_vps() {
  cmd_vps_list
  name="$(prompt "VPS profile" "$(first_profile_name)")"
  [ -n "$name" ] || return 1
  VPS_SELECT="$name"
}

tui() {
  while :; do
    say ""
    say "Warren Remote Admin"
    say "1) VPS catalog"
    say "2) Router catalog"
    say "3) Install/check remote components"
    say "4) Connect"
    say "5) Connect without timeout"
    say "6) Status"
    say "7) Close"
    say "0) Exit"
    choice="$(prompt "Choose" "")"
    case "$choice" in
      1) say ""; cmd_vps_list; say "a) add  e) edit  r) remove  enter) back"; a="$(prompt "Action" "")"; case "$a" in a) cmd_vps_add;; e) tui_select_vps && cmd_vps_edit --vps "$VPS_SELECT";; r) tui_select_vps && cmd_vps_remove --vps "$VPS_SELECT";; esac ;;
      2) tui_select_vps && cmd_routers --vps "$VPS_SELECT" ;;
      3) tui_select_vps || continue; say "1) check VPS  2) bootstrap VPS remote components  3) install router agent"; a="$(prompt "Action" "1")"; case "$a" in 1) cmd_vps_check --vps "$VPS_SELECT";; 2) cmd_vps_install_helper --vps "$VPS_SELECT";; 3) host="$(prompt "Router host" "")"; [ -n "$host" ] && cmd_router_install_agent install-agent --vps "$VPS_SELECT" --host "$host";; esac ;;
      4) tui_select_vps || continue; load_profile "$VPS_SELECT"; cmd_routers --vps "$VPS_SELECT" || true; rid="$(prompt "Router ID" "${DEFAULT_ROUTER_ID:-}")"; cmd_connect --vps "$VPS_SELECT" --router "$rid" ;;
      5) tui_select_vps || continue; load_profile "$VPS_SELECT"; cmd_routers --vps "$VPS_SELECT" || true; rid="$(prompt "Router ID" "${DEFAULT_ROUTER_ID:-}")"; cmd_connect --no-timeout --vps "$VPS_SELECT" --router "$rid" ;;
      6) tui_select_vps || continue; load_profile "$VPS_SELECT"; rid="$(prompt "Router ID" "${DEFAULT_ROUTER_ID:-}")"; cmd_status --vps "$VPS_SELECT" --router "$rid" ;;
      7) tui_select_vps || continue; load_profile "$VPS_SELECT"; rid="$(prompt "Router ID" "${DEFAULT_ROUTER_ID:-}")"; cmd_close --vps "$VPS_SELECT" --router "$rid" ;;
    0) exit 0 ;;
      *) show_usage ;;
    esac
  done
}

cmd="${1:-}"
[ -n "$cmd" ] || { tui; exit 0; }
shift || true

case "$cmd" in
  setup) cmd_setup ;;
  config) cmd_vps_list ;;
  vps)
    sub="${1:-}"; shift || true
    case "$sub" in
      add) cmd_vps_add "$@" ;;
      edit) cmd_vps_edit "$@" ;;
      remove|rm) cmd_vps_remove "$@" ;;
      list) cmd_vps_list ;;
      check) cmd_vps_check "$@" ;;
      bootstrap|install-helper) cmd_vps_install_helper "$@" ;;
      *) show_usage; exit 2 ;;
    esac
    ;;
  routers) cmd_routers "$@" ;;
  connect)
    if [ "${1:-}" != "" ] && [ "${1#--}" = "$1" ]; then
      router="$1"
      shift
      cmd_connect --router "$router" "$@"
    else
      cmd_connect "$@"
    fi
    ;;
  status)
    if [ "${1:-}" != "" ] && [ "${1#--}" = "$1" ]; then
      router="$1"
      shift
      cmd_status --router "$router" "$@"
    else
      cmd_status "$@"
    fi
    ;;
  request)
    if [ "${1:-}" != "" ] && [ "${1#--}" = "$1" ]; then
      router="$1"
      shift
      legacy_ttl="${1:-}"
      if [ -n "$legacy_ttl" ] && [ "${legacy_ttl#--}" = "$legacy_ttl" ]; then
        shift
        cmd_request --router "$router" --ttl "$legacy_ttl" "$@"
      else
        cmd_request --router "$router" "$@"
      fi
    else
      cmd_request "$@"
    fi
    ;;
  close)
    if [ "${1:-}" != "" ] && [ "${1#--}" = "$1" ]; then
      router="$1"
      shift
      cmd_close --router "$router" "$@"
    else
      cmd_close "$@"
    fi
    ;;
  router) cmd_router_install_agent "$@" ;;
  list) load_profile "$(first_profile_name)"; remote_helper list ;;
  *) show_usage; exit 2 ;;
esac
