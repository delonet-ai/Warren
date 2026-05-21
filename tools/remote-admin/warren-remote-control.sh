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
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vps) VPS_SELECT="${2:-}"; shift 2 ;;
      --router) ROUTER_ID="${2:-}"; shift 2 ;;
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

write_vps_helper_file() {
  target="$1"
  cat > "$target" <<'EOF'
#!/bin/sh
set -eu
BASE_DIR="${WARREN_REMOTE_ADMIN_BASE_DIR:-/var/lib/warren-remote}"
ROUTERS_DIR="${BASE_DIR}/routers"
REQUESTS_DIR="${BASE_DIR}/requests"
NEXT_PORT_FILE="${BASE_DIR}/next-port"
DEFAULT_PORT_BASE="${WARREN_REMOTE_ADMIN_PORT_BASE:-22000}"
now_epoch(){ date +%s 2>/dev/null || echo 0; }
ensure_dirs(){ mkdir -p "$ROUTERS_DIR" "$REQUESTS_DIR"; [ -f "$NEXT_PORT_FILE" ] || printf "%s\n" "$DEFAULT_PORT_BASE" > "$NEXT_PORT_FILE"; }
sanitize_id(){ printf "%s" "$1" | tr -cs 'A-Za-z0-9._-' '-'; }
safe_text(){ printf "%s" "$1" | tr ' ' '_'; }
hash_text(){ if command -v sha256sum >/dev/null 2>&1; then printf "%s" "$1" | sha256sum | awk '{print $1}'; else printf "%s" "$1" | cksum | awk '{print $1}'; fi; }
router_file(){ printf "%s/%s.env" "$ROUTERS_DIR" "$(sanitize_id "$1")"; }
request_file(){ printf "%s/%s.env" "$REQUESTS_DIR" "$(sanitize_id "$1")"; }
load_router(){ file="$(router_file "$1")"; [ -r "$file" ] && . "$file" || true; }
write_env(){ file="$1"; shift; tmp="${file}.tmp.$$"; : > "$tmp"; for pair in "$@"; do printf "%s\n" "$pair" >> "$tmp"; done; mv "$tmp" "$file"; }
allocate_ports(){ next="$(cat "$NEXT_PORT_FILE" 2>/dev/null || printf "%s" "$DEFAULT_PORT_BASE")"; case "$next" in ''|*[!0-9]*) next="$DEFAULT_PORT_BASE";; esac; ssh_port="$next"; luci_port=$((next+1)); printf "%s\n" $((next+10)) > "$NEXT_PORT_FILE"; printf "%s %s\n" "$ssh_port" "$luci_port"; }
router_seen(){ router_id="$1"; router_name="${2:-$1}"; pubkey="${3:-}"; source_host="${4:-}"; last_seen="$(now_epoch)"; file="$(router_file "$router_id")"; pubkey_hash="$pubkey"; if [ -n "$pubkey_hash" ] && ! printf "%s" "$pubkey_hash" | grep -Eq '^[A-Fa-f0-9]{64}$'; then pubkey_hash="$(hash_text "$pubkey_hash")"; fi; mkdir -p "$ROUTERS_DIR"; { printf "ROUTER_ID=%s\n" "$router_id"; printf "ROUTER_NAME=%s\n" "$(safe_text "$router_name")"; printf "ROUTER_PUBLIC_KEY_SHA256=%s\n" "$pubkey_hash"; printf "ROUTER_SOURCE=%s\n" "$(safe_text "$source_host")"; printf "LAST_SEEN=%s\n" "$last_seen"; printf "LAST_HEARTBEAT=%s\n" "$last_seen"; printf "TUNNEL_STATUS=%s\n" "${TUNNEL_STATUS:-down}"; printf "TUNNEL_SSH_PORT=%s\n" "${TUNNEL_SSH_PORT:-}"; printf "TUNNEL_LUCI_PORT=%s\n" "${TUNNEL_LUCI_PORT:-}"; printf "REQUEST_STATE=%s\n" "${REQUEST_STATE:-none}"; printf "REQUEST_AT=%s\n" "${REQUEST_AT:-}"; printf "REQUEST_TTL=%s\n" "${REQUEST_TTL:-}"; printf "REQUEST_ID=%s\n" "${REQUEST_ID:-}"; printf "REQUEST_EXPIRES=%s\n" "${REQUEST_EXPIRES:-}"; } > "$file"; }
request_state(){ router_id="$1"; file="$(request_file "$router_id")"; [ -r "$file" ] || return 1; . "$file"; now="$(now_epoch)"; case "${REQUEST_EXPIRES:-0}" in ''|*[!0-9]*) return 1;; esac; [ "$now" -le "$REQUEST_EXPIRES" ] || { rm -f "$file"; return 1; }; }
request_create(){ router_id="$1"; ttl="${2:-900}"; router_name="${3:-$router_id}"; ensure_dirs; load_router "$router_id"; ports="$(allocate_ports)"; tunnel_ssh_port="$(printf "%s" "$ports" | awk '{print $1}')"; tunnel_luci_port="$(printf "%s" "$ports" | awk '{print $2}')"; request_id="$(date +%Y%m%d%H%M%S)-$(sanitize_id "$router_id")"; request_at="$(now_epoch)"; request_expires=$((request_at+ttl)); write_env "$(request_file "$router_id")" "ROUTER_ID=${router_id}" "ROUTER_NAME=$(safe_text "$router_name")" "REQUEST_ID=${request_id}" "REQUEST_STATE=requested" "REQUEST_AT=${request_at}" "REQUEST_TTL=${ttl}" "REQUEST_EXPIRES=${request_expires}" "TUNNEL_SSH_PORT=${tunnel_ssh_port}" "TUNNEL_LUCI_PORT=${tunnel_luci_port}" "REQUESTED_BY=ssh"; router_seen "$router_id" "$router_name" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${SSH_CONNECTION:-}"; printf "ACTION=OPEN\nREQUEST_ID=%s\nREQUEST_TTL=%s\nTUNNEL_SSH_PORT=%s\nTUNNEL_LUCI_PORT=%s\n" "$request_id" "$ttl" "$tunnel_ssh_port" "$tunnel_luci_port"; }
request_close(){ router_id="$1"; rm -f "$(request_file "$router_id")"; load_router "$router_id"; TUNNEL_STATUS=down TUNNEL_SSH_PORT= TUNNEL_LUCI_PORT= REQUEST_STATE=closed router_seen "$router_id" "${ROUTER_NAME:-$router_id}" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${ROUTER_SOURCE:-}"; }
poll_router(){ router_id="$1"; router_name="${2:-$1}"; pubkey="${3:-}"; source_host="${4:-${SSH_CONNECTION:-}}"; ensure_dirs; if request_state "$router_id"; then . "$(request_file "$router_id")"; router_seen "$router_id" "$router_name" "$pubkey" "$source_host"; printf "ACTION=OPEN\nREQUEST_ID=%s\nREQUEST_TTL=%s\nTUNNEL_SSH_PORT=%s\nTUNNEL_LUCI_PORT=%s\n" "${REQUEST_ID:-}" "${REQUEST_TTL:-}" "${TUNNEL_SSH_PORT:-}" "${TUNNEL_LUCI_PORT:-}"; else router_seen "$router_id" "$router_name" "$pubkey" "$source_host"; printf "ACTION=NONE\n"; fi; }
tunnel_up(){ router_id="$1"; request_id="${2:-}"; tunnel_ssh_port="${3:-}"; tunnel_luci_port="${4:-}"; load_router "$router_id"; TUNNEL_STATUS=up TUNNEL_SSH_PORT="$tunnel_ssh_port" TUNNEL_LUCI_PORT="$tunnel_luci_port" REQUEST_STATE=requested REQUEST_ID="$request_id" router_seen "$router_id" "${ROUTER_NAME:-$router_id}" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${ROUTER_SOURCE:-}"; printf "TUNNEL_STATUS=up\n"; }
tunnel_down(){ router_id="$1"; request_id="${2:-}"; load_router "$router_id"; TUNNEL_STATUS=down TUNNEL_SSH_PORT= TUNNEL_LUCI_PORT= REQUEST_STATE=closed REQUEST_ID="$request_id" router_seen "$router_id" "${ROUTER_NAME:-$router_id}" "${ROUTER_PUBLIC_KEY_SHA256:-}" "${ROUTER_SOURCE:-}"; printf "TUNNEL_STATUS=down\n"; }
router_status(){ router_id="$1"; file="$(router_file "$router_id")"; [ -r "$file" ] || exit 1; cat "$file"; printf "REQUEST_ACTIVE=%s\n" "$(request_state "$router_id" && printf yes || printf no)"; }
router_list(){ ensure_dirs; printf "ROUTER_ID|ROUTER_NAME|LAST_SEEN|REQUEST_STATE|TUNNEL_STATUS|SSH_PORT|LUCI_PORT\n"; for file in "$ROUTERS_DIR"/*.env; do [ -r "$file" ] || continue; . "$file"; req=none; request_state "${ROUTER_ID:-}" && req=requested || true; printf "%s|%s|%s|%s|%s|%s|%s\n" "${ROUTER_ID:-}" "${ROUTER_NAME:-}" "${LAST_SEEN:-}" "$req" "${TUNNEL_STATUS:-down}" "${TUNNEL_SSH_PORT:-}" "${TUNNEL_LUCI_PORT:-}"; done; }
cleanup(){ ensure_dirs; now="$(now_epoch)"; for file in "$REQUESTS_DIR"/*.env; do [ -r "$file" ] || continue; . "$file"; case "${REQUEST_EXPIRES:-0}" in ''|*[!0-9]*) continue;; esac; [ "$now" -le "$REQUEST_EXPIRES" ] || rm -f "$file"; done; }
install_cron(){ if [ -d /etc/cron.d ]; then printf "*/5 * * * * root %s cleanup >/dev/null 2>&1\n" "$0" >/etc/cron.d/warren-remote; chmod 644 /etc/cron.d/warren-remote 2>/dev/null || true; fi; }
cmd="${1:-}"; shift || true
case "$cmd" in
  init) ensure_dirs; install_cron ;;
  list) router_list ;;
  request) request_create "${1:?missing router_id}" "${2:-900}" "${3:-$1}" ;;
  close) request_close "${1:?missing router_id}" ;;
  status) router_status "${1:?missing router_id}" ;;
  poll) poll_router "${1:?missing router_id}" "${2:-$1}" "${3:-}" "${4:-${SSH_CONNECTION:-}}" ;;
  tunnel-up) tunnel_up "${1:?missing router_id}" "${2:-}" "${3:-}" "${4:-}" ;;
  tunnel-down) tunnel_down "${1:?missing router_id}" "${2:-}" ;;
  cleanup) cleanup ;;
  *) echo "Usage: warren-remote {init|list|request|close|status|poll|tunnel-up|tunnel-down|cleanup}" >&2; exit 2 ;;
esac
EOF
  chmod 700 "$target"
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
    scp -P "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$ROUTER_KEY_PATH" "$src" "${ROUTER_USER}@${ROUTER_HOST}:$dst"
  else
    scp -P "$ROUTER_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "${ROUTER_USER}@${ROUTER_HOST}:$dst"
  fi
}

write_router_agent_file() {
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
now_epoch(){ date +%s 2>/dev/null || echo 0; }
log(){ printf "[%s] %s\n" "$(date +'%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG_FILE"; }
sha256_text(){ if command -v sha256sum >/dev/null 2>&1; then printf "%s" "$1" | sha256sum | awk '{print $1}'; else printf "%s" "$1" | cksum | awk '{print $1}'; fi; }
load_config(){ [ -r "$CONFIG" ] || return 1; . "$CONFIG"; [ -n "${REMOTE_ADMIN_ROUTER_ID:-}" ] || return 1; [ -n "${REMOTE_ADMIN_ENDPOINTS:-}" ] || return 1; [ -n "${REMOTE_ADMIN_ROUTER_KEY_PATH:-}" ] || return 1; REMOTE_ADMIN_ROUTER_NAME="${REMOTE_ADMIN_ROUTER_NAME:-$REMOTE_ADMIN_ROUTER_ID}"; REMOTE_ADMIN_VPS_USER="${REMOTE_ADMIN_VPS_USER:-root}"; REMOTE_ADMIN_POLL_INTERVAL="${REMOTE_ADMIN_POLL_INTERVAL:-300}"; REMOTE_ADMIN_LOCAL_SSH_PORT="${REMOTE_ADMIN_LOCAL_SSH_PORT:-2201}"; REMOTE_ADMIN_LOCAL_LUCI_PORT="${REMOTE_ADMIN_LOCAL_LUCI_PORT:-8081}"; }
ensure_state_dir(){ mkdir -p "$STATE_DIR"; }
endpoint_candidates(){ printf "%s\n" "${REMOTE_ADMIN_ENDPOINTS:-}" | tr ',;' '\n' | sed '/^$/d'; }
split_endpoint(){ endpoint="$1"; host="${endpoint%:*}"; port="${endpoint##*:}"; case "$endpoint" in *:*) printf "%s %s" "$host" "$port";; *) printf "%s %s" "$endpoint" "22";; esac; }
ssh_base(){ ssh -i "$REMOTE_ADMIN_ROUTER_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$@"; }
helper_call(){ endpoint="$1"; shift; set -- $(split_endpoint "$endpoint") "$@"; host="$1"; port="$2"; shift 2; ssh_base -p "$port" "${REMOTE_ADMIN_VPS_USER}@${host}" "warren-remote $*"; }
current_pid(){ [ -s "$PID_FILE" ] || return 1; cat "$PID_FILE"; }
discover_tunnel_pid(){ tunnel_ssh_port="${1:-}"; tunnel_luci_port="${2:-}"; ps w 2>/dev/null | awk -v ssh_port="$tunnel_ssh_port" -v luci_port="$tunnel_luci_port" 'index($0, "ssh -N") && index($0, "-R 127.0.0.1:" ssh_port ":127.0.0.1:22") && index($0, "-R 127.0.0.1:" luci_port ":127.0.0.1:80") { print $1; exit }'; }
stop_tunnel(){ if pid="$(current_pid 2>/dev/null || true)"; then kill "$pid" >/dev/null 2>&1 || true; fi; rm -f "$PID_FILE" "$CURRENT_PORTS_FILE"; }
write_last_poll(){ { printf "LAST_POLL_AT=%s\n" "$(now_epoch)"; printf "LAST_POLL_ACTION=%s\n" "${1:-}"; printf "LAST_POLL_ENDPOINT=%s\n" "${2:-}"; printf "LAST_POLL_RESULT=%s\n" "${3:-}"; printf "LAST_POLL_REQUEST_ID=%s\n" "${4:-}"; } > "$LAST_POLL_FILE"; }
tunnel_running(){ if pid="$(current_pid 2>/dev/null || true)"; then kill -0 "$pid" >/dev/null 2>&1; else return 1; fi; }
start_tunnel(){ endpoint_host="$1"; endpoint_port="$2"; tunnel_ssh_port="$3"; tunnel_luci_port="$4"; ensure_state_dir; if tunnel_running; then return 0; fi; if command -v autossh >/dev/null 2>&1; then tunnel_cmd="exec autossh -M 0 -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -i \"$REMOTE_ADMIN_ROUTER_KEY_PATH\" -p \"$endpoint_port\" -R 127.0.0.1:${tunnel_ssh_port}:127.0.0.1:22 -R 127.0.0.1:${tunnel_luci_port}:127.0.0.1:80 ${REMOTE_ADMIN_VPS_USER}@${endpoint_host}"; else tunnel_cmd="exec ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -i \"$REMOTE_ADMIN_ROUTER_KEY_PATH\" -p \"$endpoint_port\" -R 127.0.0.1:${tunnel_ssh_port}:127.0.0.1:22 -R 127.0.0.1:${tunnel_luci_port}:127.0.0.1:80 ${REMOTE_ADMIN_VPS_USER}@${endpoint_host}"; fi; if command -v setsid >/dev/null 2>&1; then setsid sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null & elif command -v nohup >/dev/null 2>&1; then nohup sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null & else sh -c "$tunnel_cmd" >>"$LOG_FILE" 2>&1 </dev/null & fi; pid="$!"; printf "%s\n" "$pid" > "$PID_FILE"; { printf "TUNNEL_SSH_PORT=%s\n" "$tunnel_ssh_port"; printf "TUNNEL_LUCI_PORT=%s\n" "$tunnel_luci_port"; printf "TUNNEL_STARTED_AT=%s\n" "$(now_epoch)"; } > "$CURRENT_PORTS_FILE"; sleep 2; tunnel_running; }
report_status(){ load_config || true; printf "ROUTER_ID=%s\nROUTER_NAME=%s\nENDPOINTS=%s\n" "${REMOTE_ADMIN_ROUTER_ID:-}" "${REMOTE_ADMIN_ROUTER_NAME:-}" "${REMOTE_ADMIN_ENDPOINTS:-}"; [ -r "$LAST_POLL_FILE" ] && sed -n 's/^LAST_POLL_AT=/LAST_POLL_AT=/p;s/^LAST_POLL_ACTION=/LAST_POLL_ACTION=/p;s/^LAST_POLL_ENDPOINT=/LAST_POLL_ENDPOINT=/p;s/^LAST_POLL_RESULT=/LAST_POLL_RESULT=/p;s/^LAST_POLL_REQUEST_ID=/LAST_POLL_REQUEST_ID=/p' "$LAST_POLL_FILE"; if [ -s "$DAEMON_PID_FILE" ]; then daemon_pid="$(cat "$DAEMON_PID_FILE" 2>/dev/null || true)"; printf "DAEMON_PID=%s\n" "$daemon_pid"; if kill -0 "$daemon_pid" >/dev/null 2>&1; then printf "DAEMON_STATUS=up\n"; else printf "DAEMON_STATUS=down\n"; fi; else if ps w 2>/dev/null | grep -F "/usr/bin/warren-remote-agent daemon" >/dev/null 2>&1; then printf "DAEMON_STATUS=up\n"; else printf "DAEMON_STATUS=unknown\n"; fi; fi; if tunnel_running; then tunnel_pid="$(current_pid 2>/dev/null || true)"; if [ -z "$tunnel_pid" ]; then tunnel_pid="$(discover_tunnel_pid "$(sed -n 's/^TUNNEL_SSH_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)" "$(sed -n 's/^TUNNEL_LUCI_PORT=//p' "$CURRENT_PORTS_FILE" 2>/dev/null | head -n1)")"; [ -n "$tunnel_pid" ] && printf "%s\n" "$tunnel_pid" > "$PID_FILE" 2>/dev/null || true; fi; printf "TUNNEL_STATUS=up\n"; sed -n 's/^TUNNEL_SSH_PORT=/TUNNEL_SSH_PORT=/p;s/^TUNNEL_LUCI_PORT=/TUNNEL_LUCI_PORT=/p' "$CURRENT_PORTS_FILE"; printf "TUNNEL_PID=%s\n" "${tunnel_pid:-$(cat "$PID_FILE" 2>/dev/null || true)}"; else printf "TUNNEL_STATUS=down\n"; fi; }
poll_once(){ load_config || { log "config unavailable"; return 1; }; ensure_state_dir; response=; chosen=; for endpoint in $(endpoint_candidates); do if tmp="$(helper_call "$endpoint" poll "$REMOTE_ADMIN_ROUTER_ID" "$REMOTE_ADMIN_ROUTER_NAME" "$(sha256_text "$(cat "$REMOTE_ADMIN_ROUTER_KEY_PATH.pub" 2>/dev/null || printf "")")" 2>/dev/null)"; then response="$tmp"; chosen="$endpoint"; action="$(printf "%s\n" "$response" | sed -n 's/^ACTION=//p' | head -n1)"; [ "$action" = OPEN ] || [ "$action" = CLOSE ] && break; fi; done; if [ -z "$response" ]; then log "no responsive endpoint for $REMOTE_ADMIN_ROUTER_ID ${chosen:+(last tried: $chosen)}"; write_last_poll "NONE" "$chosen" "no-response" ""; return 1; fi; action="$(printf "%s\n" "$response" | sed -n 's/^ACTION=//p' | head -n1)"; ssh_port="$(printf "%s\n" "$response" | sed -n 's/^TUNNEL_SSH_PORT=//p' | head -n1)"; luci_port="$(printf "%s\n" "$response" | sed -n 's/^TUNNEL_LUCI_PORT=//p' | head -n1)"; request_id="$(printf "%s\n" "$response" | sed -n 's/^REQUEST_ID=//p' | head -n1)"; set -- $(split_endpoint "$chosen"); case "$action" in OPEN) start_tunnel "$1" "$2" "$ssh_port" "$luci_port" && helper_call "$chosen" tunnel-up "$REMOTE_ADMIN_ROUTER_ID" "$request_id" "$ssh_port" "$luci_port" >/dev/null 2>&1 || true; write_last_poll "OPEN" "$chosen" "tunnel-up" "$request_id";; CLOSE) stop_tunnel; helper_call "$chosen" tunnel-down "$REMOTE_ADMIN_ROUTER_ID" "$request_id" >/dev/null 2>&1 || true; write_last_poll "CLOSE" "$chosen" "tunnel-down" "$request_id";; NONE|"") if ! tunnel_running; then rm -f "$PID_FILE" "$CURRENT_PORTS_FILE" >/dev/null 2>&1 || true; fi; write_last_poll "NONE" "$chosen" "idle" "$request_id";; esac; }
daemon_loop(){ load_config || exit 1; ensure_state_dir; printf "%s\n" "$$" > "$DAEMON_PID_FILE"; trap 'rm -f "$DAEMON_PID_FILE" >/dev/null 2>&1 || true' EXIT INT TERM; while :; do poll_once || true; sleep "${REMOTE_ADMIN_POLL_INTERVAL:-30}"; done; }
case "${1:-daemon}" in daemon) daemon_loop;; poll) poll_once;; status) report_status;; stop) stop_tunnel;; *) echo "Usage: warren-remote-agent {daemon|poll|status|stop}" >&2; exit 2;; esac
EOF
  chmod 700 "$target"
}

write_router_init_file() {
  target="$1"
  cat > "$target" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service(){ procd_open_instance; procd_set_param command /usr/bin/warren-remote-agent daemon; procd_set_param respawn 3600 5 0; procd_close_instance; }
stop_service(){ /usr/bin/warren-remote-agent stop >/dev/null 2>&1 || true; }
EOF
  chmod 755 "$target"
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
  escaped_pubkey="$(quote_sh "$pubkey")"
  ssh_cmd "sh -lc 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF $escaped_pubkey ~/.ssh/authorized_keys || printf \"%s\n\" $escaped_pubkey >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'"
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
  request) load_profile "$(first_profile_name)"; remote_helper request "${1:-${DEFAULT_ROUTER_ID:-}}" "${2:-$REQUEST_TTL}" ;;
  *) show_usage; exit 2 ;;
esac
