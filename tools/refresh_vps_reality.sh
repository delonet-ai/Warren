#!/bin/sh
set -eu

# Default: the newest VPS report on the router; override with REPORT_FILE=...
REPORT_FILE="${REPORT_FILE:-$(ls -1t /etc/warren/vps/reports/*.txt 2>/dev/null | head -n1)}"
WARREN_LIB_DIR="${WARREN_LIB_DIR:-/usr/lib/warren/lib}"
WARREN_BASE_DIR="${WARREN_BASE_DIR:-/etc/warren}"
WARREN_LOG_DIR="${WARREN_LOG_DIR:-/root/warren}"
CONF="${CONF:-${WARREN_BASE_DIR}/warren.conf}"
STATE="${STATE:-${WARREN_BASE_DIR}/warren.state}"
LOG="${LOG:-${WARREN_LOG_DIR}/warren.log}"
LIB_CACHE_DIR="${LIB_CACHE_DIR:-/tmp/warren-lib}"
ASSET_CACHE_DIR="${ASSET_CACHE_DIR:-/tmp/warren-assets}"
AUTO_STATE_JSON="${AUTO_STATE_JSON:-/tmp/warren-runtime.json}"
AUTO_STATE_STORE="${AUTO_STATE_STORE:-/tmp/warren-runtime.tsv}"

[ -n "$REPORT_FILE" ] && [ -r "$REPORT_FILE" ] || {
  echo "missing report: ${REPORT_FILE:-/etc/warren/vps/reports/*.txt}; set REPORT_FILE=..." >&2
  exit 1
}

for lib in common.sh state.sh ui.sh vps.sh; do
  . "$WARREN_LIB_DIR/$lib"
done

extract_field() {
  field="$1"
  sed -n "s/^${field}: //p" "$REPORT_FILE" | head -n1
}

VPS_HOST="$(extract_field "Host")"
VPS_SSH_PORT="$(extract_field "SSH port")"
VPS_ROOT_PASSWORD="$(extract_field "SSH root password")"
PANEL_URL="$(extract_field "3x-ui URL")"
PANEL_USERNAME="$(extract_field "3x-ui username")"
PANEL_PASSWORD="$(extract_field "3x-ui password")"

[ -n "$VPS_HOST" ] || { echo "missing VPS host in report" >&2; exit 1; }
[ -n "$VPS_SSH_PORT" ] || VPS_SSH_PORT=22
[ -n "$PANEL_URL" ] || { echo "missing panel url in report" >&2; exit 1; }
[ -n "$PANEL_USERNAME" ] || { echo "missing panel username in report" >&2; exit 1; }
[ -n "$PANEL_PASSWORD" ] || { echo "missing panel password in report" >&2; exit 1; }

mkdir -p "$(dirname "$REPORT_FILE")" "${WARREN_BASE_DIR}/vps" || true
load_conf_if_exists || true

VPS_KEY_PATH="$(ls /etc/warren/vps/keys/${VPS_HOST}*_ed25519 2>/dev/null | head -n1 || true)"
[ -n "$VPS_KEY_PATH" ] || {
  echo "missing VPS SSH key for $VPS_HOST" >&2
  exit 1
}

export VPS_HOST VPS_SSH_PORT VPS_ROOT_PASSWORD VPS_KEY_PATH PANEL_URL PANEL_USERNAME PANEL_PASSWORD

collect_3xui_access_info
generate_reality_materials
create_vless_reality_payload

ssh -i "$VPS_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${VPS_HOST}" "sh -lc '
  set -eu
  cfg=/usr/local/x-ui/bin/config.json
  tmp=\$(mktemp /tmp/warren-xui-config.XXXXXX)
  sed \"s/\\\"privateKey\\\": \\\"[^\\\"]*\\\"/\\\"privateKey\\\": \\\"${REALITY_PRIVATE_KEY}\\\"/\" \"\$cfg\" > \"\$tmp\"
  mv \"\$tmp\" \"\$cfg\"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart x-ui
  else
    service x-ui restart
  fi
'"

build_vless_link

{
  printf "Warren VPS setup report\n"
  printf "=======================\n\n"
  printf "VLESS inbound link: %s\n\n" "${VLESS_LINK:-unknown}"
  printf "Host: %s\n" "$VPS_HOST"
  printf "SSH port: %s\n" "$VPS_SSH_PORT"
  printf "SSH root login: %s\n" "root"
  printf "SSH root password: %s\n" "${VPS_ROOT_PASSWORD:-unknown}"
  printf "OS: %s\n" "${VPS_OS_PRETTY:-unknown}"
  printf "3x-ui URL: %s\n" "${PANEL_URL:-unknown}"
  printf "3x-ui username: %s\n" "${PANEL_USERNAME:-unknown}"
  printf "3x-ui password: %s\n" "${PANEL_PASSWORD:-unknown}"
  printf "\nReality public key: %s\n" "${REALITY_PUBLIC_KEY:-unknown}"
  printf "Reality short id: %s\n" "${SID_PRIMARY:-unknown}"
  printf "Client email: %s\n" "${CLIENT_EMAIL:-unknown}"
  printf "Client uuid: %s\n" "${CLIENT_UUID:-unknown}"
  printf "Reality config status: %s\n" "created"
} > "$REPORT_FILE"

printf "%s\n" "VLESS refreshed: ${VLESS_LINK:-unknown}"
