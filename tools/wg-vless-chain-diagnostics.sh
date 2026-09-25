#!/bin/sh
# Diagnostics for macOS WireGuard -> OpenWrt -> Podkop/sing-box/VLESS chains.
# Default mode is read-only. --auto-toggle-wg is opt-in and changes local WG state.

set -u

SCRIPT_NAME="$(basename "$0")"
TS="$(date +'%Y%m%d-%H%M%S' 2>/dev/null || date)"
ORIG_ARGC=$#

ROUTER="${ROUTER:-router}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
WG_SERVER="${WG_SERVER:-}"
WG_PORT="${WG_PORT:-51820}"
WG_IFACE="${WG_IFACE:-auto}"
LAN_TARGET="${LAN_TARGET:-192.168.0.1}"
RF_TARGET="${RF_TARGET:-ya.ru}"
FOREIGN_TARGET="${FOREIGN_TARGET:-google.com}"
VPS_HOST="${VPS_HOST:-}"
COUNT="${COUNT:-20}"
LOSS_COUNT="${LOSS_COUNT:-240}"
LOSS_INTERVAL="${LOSS_INTERVAL:-0.5}"
MTU_MIN="${MTU_MIN:-1200}"
MTU_MAX="${MTU_MAX:-1500}"
SPEED_ENABLED="${SPEED_ENABLED:-1}"
SPEED_SECONDS="${SPEED_SECONDS:-10}"
SPEED_URL_RF="${SPEED_URL_RF:-https://speedtest.selectel.ru/100MB}"
SPEED_URL_FOREIGN="${SPEED_URL_FOREIGN:-https://speed.cloudflare.com/__down?bytes=25000000}"
IPERF_HOST="${IPERF_HOST:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
ROUTER_IPERF_SERVER="${ROUTER_IPERF_SERVER:-1}"
OPENWRT_REMOTE_TIMEOUT="${OPENWRT_REMOTE_TIMEOUT:-180}"
AUTO_TOGGLE_WG="${AUTO_TOGGLE_WG:-0}"
WG_CONTROL="${WG_CONTROL:-auto}"
WG_SERVICE="${WG_SERVICE:-}"
WG_QUICK_NAME="${WG_QUICK_NAME:-}"
WG_UP_CMD="${WG_UP_CMD:-}"
WG_DOWN_CMD="${WG_DOWN_CMD:-}"
WG_SETTLE_SECONDS="${WG_SETTLE_SECONDS:-8}"
RESTORE_WG="${RESTORE_WG:-initial}"
OUT_DIR="${OUT_DIR:-}"
WRITE_JSON=0
SHOW_MENU=0
FORCE_NO_MENU=0
PROGRESS_ENABLED="${PROGRESS_ENABLED:-1}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"
PROGRESS_WAIT_TIMEOUT_HIT=0
PROGRESS_TOTAL=16
PROGRESS_CURRENT=0
PROFILE_NAME="custom"
INITIAL_WG_STATE="unknown"
WG_RESTORE_DONE=0

OK_COUNT=0
WARN_COUNT=0
BAD_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<EOF
Usage:
  sh $SCRIPT_NAME [options]

Options:
  --menu                       Show interactive profile menu
  --no-menu                    Never show menu; useful when running with no args
  --no-progress                Disable live progress indicators
  --progress-interval 5        Seconds between live progress refreshes
  --router router              OpenWrt SSH target, default: router
  --ssh-port 22                SSH port for --router
  --ssh-key path               SSH private key for --router
  --wg-server host             Public WireGuard server endpoint (required for WG checks)
  --wg-port 51820              WireGuard UDP port, default: 51820
  --wg-iface auto|utunN|name    WireGuard interface hint on macOS
  --lan-target host            Target behind WG, default: 192.168.0.1
  --rf-target host             RF/RU segment test target, default ya.ru
  --foreign-target host        Foreign/proxy test target, default google.com
  --vps-host host              Optional VPS host for direct checks
  --count 20                   Ping count
  --loss-count 240             Long loss/jitter ping count
  --loss-interval 0.5          Long loss/jitter ping interval
  --mtu-min 1200               Minimum payload size for PMTU probe
  --mtu-max 1500               Maximum payload size for PMTU probe
  --speed                      Enable speed tests, default
  --no-speed                   Disable speed tests
  --speed-seconds 10           Timed speed-test duration
  --speed-url-rf URL           RF/RU segment download URL, default: Selectel 100MB
  --speed-url-foreign URL      Foreign/proxy download URL, default: Cloudflare 25MB
  --iperf-host host            iperf3 server host, default: VPS host or WG server
  --iperf-port 5201            iperf3 server port
  --router-iperf-server        Temporarily run iperf3 -s -1 on OpenWrt, default
  --no-router-iperf-server     Do not auto-start temporary OpenWrt iperf3 server
  --openwrt-timeout 180        Max seconds for OpenWrt remote diagnostics
  --auto-toggle-wg             Opt-in A/B test: WG off baseline, WG on full chain
  --wg-control auto|scutil|wg-quick|cmd
                               WG control backend for --auto-toggle-wg
  --wg-service name            macOS VPN service name for scutil --nc start/stop
  --wg-quick-name name         wg-quick tunnel name/path for wg-quick up/down
  --wg-up-cmd cmd              Explicit shell command to enable WG
  --wg-down-cmd cmd            Explicit shell command to disable WG
  --wg-settle-seconds 8        Wait after WG state changes
  --restore-wg initial|on|off|none
                               State to restore after --auto-toggle-wg, default initial
  --out dir                    Exact output report directory
  --json                       Also write summary.json
  -h, --help                   Show this help

Default mode is read-only: it does not restart services, edit UCI, edit firewall,
or change routes. --auto-toggle-wg is explicit opt-in and starts/stops local WG.
Missing tools are logged to missing-tools.txt.
EOF
}

detect_default_wg_service_name() {
  if command -v scutil >/dev/null 2>&1; then
    scutil --nc list 2>/dev/null | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

prompt_default() {
  prompt="$1"
  default="$2"
  printf "%s [%s]: " "$prompt" "$default"
  IFS= read -r answer || answer=""
  if [ -n "$answer" ]; then
    printf "%s\n" "$answer"
  else
    printf "%s\n" "$default"
  fi
}

interactive_menu() {
  default_service="$(detect_default_wg_service_name)"
  [ -n "$default_service" ] || default_service="home"

  printf "\nWireGuard/VLESS/OpenWrt diagnostics\n"
  printf "===================================\n"
  printf "1) Быстрый read-only: Mac/uplink/WG endpoint, короткие ping, без SSH и speed\n"
  printf "2) Стандартный read-only: вся цепочка + OpenWrt + speed + loss около 2 минут на цель\n"
  printf "3) Длинный read-only: вся цепочка + усиленный loss около 5 минут на цель\n"
  printf "4) Полный A/B: сам выключит WG, проверит baseline, включит WG и проверит всю цепочку\n"
  printf "5) Длинный A/B: как 4, но с усиленным loss\n"
  printf "q) Выход\n\n"
  printf "Выбор: "
  IFS= read -r choice || exit 1

  case "$choice" in
    1)
      PROFILE_NAME="quick"
      ROUTER=""
      COUNT=5
      LOSS_COUNT=30
      LOSS_INTERVAL=0.5
      SPEED_ENABLED=0
      AUTO_TOGGLE_WG=0
      ;;
    2)
      PROFILE_NAME="standard"
      ROUTER="${ROUTER:-router}"
      COUNT=20
      LOSS_COUNT=240
      LOSS_INTERVAL=0.5
      SPEED_ENABLED=1
      AUTO_TOGGLE_WG=0
      ;;
    3)
      PROFILE_NAME="long"
      ROUTER="${ROUTER:-router}"
      COUNT=50
      LOSS_COUNT=600
      LOSS_INTERVAL=0.5
      SPEED_ENABLED=1
      AUTO_TOGGLE_WG=0
      ;;
    4)
      PROFILE_NAME="ab-standard"
      ROUTER="${ROUTER:-router}"
      COUNT=20
      LOSS_COUNT=240
      LOSS_INTERVAL=0.5
      SPEED_ENABLED=1
      AUTO_TOGGLE_WG=1
      WG_CONTROL="${WG_CONTROL:-auto}"
      WG_SERVICE="$(prompt_default "macOS WireGuard VPN service" "${WG_SERVICE:-$default_service}")"
      RESTORE_WG="${RESTORE_WG:-initial}"
      ;;
    5)
      PROFILE_NAME="ab-long"
      ROUTER="${ROUTER:-router}"
      COUNT=50
      LOSS_COUNT=600
      LOSS_INTERVAL=0.5
      SPEED_ENABLED=1
      AUTO_TOGGLE_WG=1
      WG_CONTROL="${WG_CONTROL:-auto}"
      WG_SERVICE="$(prompt_default "macOS WireGuard VPN service" "${WG_SERVICE:-$default_service}")"
      RESTORE_WG="${RESTORE_WG:-initial}"
      ;;
    q|Q)
      printf "Canceled.\n"
      exit 0
      ;;
    *)
      printf "Unknown choice: %s\n" "$choice" >&2
      exit 2
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --menu) SHOW_MENU=1; shift ;;
    --no-menu) FORCE_NO_MENU=1; shift ;;
    --no-progress) PROGRESS_ENABLED=0; shift ;;
    --progress-interval) PROGRESS_INTERVAL="${2:-5}"; shift 2 ;;
    --router) ROUTER="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-22}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:-}"; shift 2 ;;
    --wg-server) WG_SERVER="${2:-}"; shift 2 ;;
    --wg-port) WG_PORT="${2:-51820}"; shift 2 ;;
    --wg-iface) WG_IFACE="${2:-auto}"; shift 2 ;;
    --lan-target) LAN_TARGET="${2:-}"; shift 2 ;;
    --rf-target) RF_TARGET="${2:-ya.ru}"; shift 2 ;;
    --foreign-target) FOREIGN_TARGET="${2:-google.com}"; shift 2 ;;
    --vps-host) VPS_HOST="${2:-}"; shift 2 ;;
    --count) COUNT="${2:-20}"; shift 2 ;;
    --loss-count) LOSS_COUNT="${2:-240}"; shift 2 ;;
    --loss-interval) LOSS_INTERVAL="${2:-0.5}"; shift 2 ;;
    --mtu-min) MTU_MIN="${2:-1200}"; shift 2 ;;
    --mtu-max) MTU_MAX="${2:-1500}"; shift 2 ;;
    --speed) SPEED_ENABLED=1; shift ;;
    --no-speed) SPEED_ENABLED=0; shift ;;
    --speed-seconds) SPEED_SECONDS="${2:-10}"; shift 2 ;;
    --speed-url-rf) SPEED_URL_RF="${2:-}"; shift 2 ;;
    --speed-url-foreign) SPEED_URL_FOREIGN="${2:-}"; shift 2 ;;
    --iperf-host) IPERF_HOST="${2:-}"; shift 2 ;;
    --iperf-port) IPERF_PORT="${2:-5201}"; shift 2 ;;
    --router-iperf-server) ROUTER_IPERF_SERVER=1; shift ;;
    --no-router-iperf-server) ROUTER_IPERF_SERVER=0; shift ;;
    --openwrt-timeout) OPENWRT_REMOTE_TIMEOUT="${2:-180}"; shift 2 ;;
    --auto-toggle-wg) AUTO_TOGGLE_WG=1; shift ;;
    --wg-control) WG_CONTROL="${2:-auto}"; shift 2 ;;
    --wg-service) WG_SERVICE="${2:-}"; shift 2 ;;
    --wg-quick-name) WG_QUICK_NAME="${2:-}"; shift 2 ;;
    --wg-up-cmd) WG_UP_CMD="${2:-}"; shift 2 ;;
    --wg-down-cmd) WG_DOWN_CMD="${2:-}"; shift 2 ;;
    --wg-settle-seconds) WG_SETTLE_SECONDS="${2:-8}"; shift 2 ;;
    --restore-wg) RESTORE_WG="${2:-initial}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --json) WRITE_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf "%s\n" "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$FORCE_NO_MENU" != "1" ]; then
  if [ "$SHOW_MENU" = "1" ] || { [ "$ORIG_ARGC" -eq 0 ] && [ -t 0 ]; }; then
    interactive_menu
  fi
fi

case "$COUNT" in ''|*[!0-9]*) COUNT=20 ;; esac
case "$LOSS_COUNT" in ''|*[!0-9]*) LOSS_COUNT=240 ;; esac
case "$LOSS_INTERVAL" in ''|*[!0-9.]*|.*.*) LOSS_INTERVAL=0.5 ;; esac
case "$MTU_MIN" in ''|*[!0-9]*) MTU_MIN=1200 ;; esac
case "$MTU_MAX" in ''|*[!0-9]*) MTU_MAX=1500 ;; esac
case "$SPEED_SECONDS" in ''|*[!0-9]*) SPEED_SECONDS=10 ;; esac
case "$IPERF_PORT" in ''|*[!0-9]*) IPERF_PORT=5201 ;; esac
case "$OPENWRT_REMOTE_TIMEOUT" in ''|*[!0-9]*) OPENWRT_REMOTE_TIMEOUT=180 ;; esac
case "$WG_SETTLE_SECONDS" in ''|*[!0-9]*) WG_SETTLE_SECONDS=8 ;; esac
case "$WG_CONTROL" in auto|scutil|wg-quick|cmd) ;; *) WG_CONTROL=auto ;; esac
case "$RESTORE_WG" in initial|on|off|none) ;; *) RESTORE_WG=initial ;; esac
case "$PROGRESS_ENABLED" in 0|1) ;; *) PROGRESS_ENABLED=1 ;; esac
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*) PROGRESS_INTERVAL=5 ;; esac
[ "$PROGRESS_INTERVAL" -ge 1 ] || PROGRESS_INTERVAL=1

if [ "$AUTO_TOGGLE_WG" = "1" ]; then
  PROGRESS_TOTAL=24
elif [ -z "$ROUTER" ] && [ "$SPEED_ENABLED" != "1" ]; then
  PROGRESS_TOTAL=10
else
  PROGRESS_TOTAL=16
fi

if [ -z "$IPERF_HOST" ]; then
  if [ -n "$VPS_HOST" ]; then
    IPERF_HOST="$VPS_HOST"
  else
    IPERF_HOST="$WG_SERVER"
  fi
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="./diagnostics/wg-chain-$TS"
fi

mkdir -p "$OUT_DIR" || {
  printf "%s\n" "FAIL: cannot create output directory: $OUT_DIR" >&2
  exit 1
}

RAW_LOG="$OUT_DIR/raw.log"
SUMMARY="$OUT_DIR/summary.txt"
MISSING_TOOLS="$OUT_DIR/missing-tools.txt"
RESULTS="$OUT_DIR/results.tsv"
JSON_SUMMARY="$OUT_DIR/summary.json"
SSH_KNOWN_HOSTS="$OUT_DIR/ssh-known-hosts"

: > "$RAW_LOG"
: > "$SUMMARY"
: > "$MISSING_TOOLS"
: > "$RESULTS"
: > "$SSH_KNOWN_HOSTS"
chmod 600 "$SSH_KNOWN_HOSTS" 2>/dev/null || true

clear_proxy_environment() {
  log_raw ""
  log_raw "===== PROXY ENVIRONMENT CLEANUP ====="
  log_raw "Proxy variables before cleanup:"
  env | grep -Ei '^(all|http|https|no)_proxy=' >> "$RAW_LOG" 2>&1 || true
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  unset http_proxy https_proxy all_proxy no_proxy
  result "OK" "0 Mac/Hotspot" "proxy environment variables cleared for diagnostics process only"
}

say() {
  printf "%s\n" "$*"
}

log_raw() {
  printf "%s\n" "$*" >> "$RAW_LOG"
}

progress_pct() {
  if [ "$PROGRESS_TOTAL" -le 0 ]; then
    printf "%s" "0"
  else
    printf "%s" $((PROGRESS_CURRENT * 100 / PROGRESS_TOTAL))
  fi
}

progress_section() {
  title="$1"
  [ "$PROGRESS_ENABLED" = "1" ] || return 0
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  pct="$(progress_pct)"
  printf "\n==> [%3s%%] %s\n" "$pct" "$title"
}

progress_wait() {
  label="$1"
  pid="$2"
  expected_seconds="${3:-0}"

  [ "$PROGRESS_ENABLED" = "1" ] || return 0
  elapsed=0
  spin='|/-\'
  spin_i=1
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    ch="$(printf "%s" "$spin" | cut -c "$spin_i")"
    spin_i=$((spin_i + 1))
    [ "$spin_i" -le 4 ] || spin_i=1
    if [ "${expected_seconds:-0}" -gt 0 ]; then
      subpct=$((elapsed * 100 / expected_seconds))
      [ "$subpct" -le 99 ] || subpct=99
      printf "\r    %s running: %s, elapsed=%ss, approx=%s%%" "$ch" "$label" "$elapsed" "$subpct"
    else
      printf "\r    %s running: %s, elapsed=%ss" "$ch" "$label" "$elapsed"
    fi
  done
  printf "\r    done: %s, elapsed=%ss%*s\n" "$label" "$elapsed" 20 ""
}

progress_sleep() {
  label="$1"
  seconds="$2"
  (sleep "$seconds") &
  sleep_pid=$!
  progress_wait "$label" "$sleep_pid" "$seconds"
  wait "$sleep_pid" 2>/dev/null || true
}

redact_stream() {
  sed -E \
    -e 's/(PrivateKey|private_key|PRIVATE_KEY)([[:space:]]*[:=][[:space:]]*)[^[:space:]",}]+/\1\2<redacted>/g' \
    -e 's/(password|Password|PASSWORD|token|Token|TOKEN|secret|Secret|SECRET)([[:space:]]*[:=][[:space:]]*)[^[:space:]",}]+/\1\2<redacted>/g' \
    -e 's/(uuid|UUID|id|shortId|short_id)([[:space:]]*[:=][[:space:]]*)[0-9a-fA-F-]{8,}/\1\2<redacted>/g' \
    -e 's#(vless://)[^@[:space:]]+@#\1<redacted>@#g' \
    -e 's#([?&](id|uuid|password|pbk|sid|spx)=)[^&#[:space:]]+#\1<redacted>#g'
}

result() {
  status="$1"
  segment="$2"
  message="$3"

  case "$status" in
    OK) OK_COUNT=$((OK_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    BAD) BAD_COUNT=$((BAD_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac

  printf "%s\t%s\t%s\n" "$status" "$segment" "$message" >> "$RESULTS"
  printf "[%s] %s: %s\n" "$status" "$segment" "$message" >> "$SUMMARY"
  if [ "$PROGRESS_ENABLED" = "1" ]; then
    printf "    [%s] %s: %s\n" "$status" "$segment" "$message"
  else
    printf "[%s] %s: %s\n" "$status" "$segment" "$message"
  fi
}

section() {
  title="$1"
  log_raw ""
  log_raw "===== $title ====="
  printf "\n## %s\n" "$title" >> "$SUMMARY"
  progress_section "$title"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

missing_tool() {
  side="$1"
  tool="$2"
  impact="$3"
  printf "%s\t%s\t%s; install/enable manually\n" "$side" "$tool" "$impact" >> "$MISSING_TOOLS"
  result "SKIP" "6 Missing tools" "$side: missing $tool; skipped: $impact; install/enable manually"
}

check_tool() {
  side="$1"
  tool="$2"
  impact="$3"
  if has_cmd "$tool"; then
    result "OK" "6 Missing tools" "$side: $tool is installed"
    return 0
  fi
  missing_tool "$side" "$tool" "$impact"
  return 1
}

run_cmd() {
  title="$1"
  shift
  tmp="$OUT_DIR/.cmd.$$"

  log_raw ""
  log_raw "--- $title ---"
  log_raw "# $*"
  "$@" > "$tmp" 2>&1 &
  cmd_pid=$!
  progress_wait "$title" "$cmd_pid" 0
  wait "$cmd_pid"
  rc=$?
  redact_stream < "$tmp" >> "$RAW_LOG"
  rm -f "$tmp" 2>/dev/null || true
  log_raw "# exit=$rc"
  return "$rc"
}

run_sh() {
  title="$1"
  cmd="$2"
  run_cmd "$title" sh -c "$cmd"
}

wg_detect_state() {
  if [ -n "$WG_SERVICE" ] && has_cmd scutil; then
    state="$(scutil --nc status "$WG_SERVICE" 2>/dev/null | awk 'NR==1 {print $1}')"
    case "$state" in
      Connected) printf "%s\n" "on"; return 0 ;;
      Disconnected|Invalid|Connecting|Disconnecting) printf "%s\n" "off"; return 0 ;;
    esac
  fi

  if has_cmd wg; then
    ifaces="$(wg show interfaces 2>/dev/null || true)"
    if [ -n "$WG_QUICK_NAME" ] && printf "%s\n" "$ifaces" | grep -Eq "(^|[[:space:]])$WG_QUICK_NAME($|[[:space:]])"; then
      printf "%s\n" "on"
      return 0
    fi
    if [ -n "$ifaces" ]; then
      printf "%s\n" "on"
      return 0
    fi
  fi

  if [ -n "$(detect_wg_iface 2>/dev/null || true)" ]; then
    printf "%s\n" "on"
  else
    printf "%s\n" "off"
  fi
}

wg_control_action() {
  action="$1"
  backend="$WG_CONTROL"

  if [ "$backend" = "auto" ]; then
    if [ -n "$WG_UP_CMD" ] && [ -n "$WG_DOWN_CMD" ]; then
      backend="cmd"
    elif [ -n "$WG_SERVICE" ]; then
      backend="scutil"
    elif [ -n "$WG_QUICK_NAME" ]; then
      backend="wg-quick"
    else
      result "BAD" "9 WG auto-toggle" "no WG control method configured; set --wg-service, --wg-quick-name, or --wg-up-cmd/--wg-down-cmd"
      return 1
    fi
  fi

  case "$backend:$action" in
    scutil:on)
      if ! has_cmd scutil; then missing_tool "mac" "scutil" "WG start via scutil"; return 1; fi
      if [ -z "$WG_SERVICE" ]; then result "BAD" "9 WG auto-toggle" "--wg-service required for scutil control"; return 1; fi
      run_cmd "WG start via scutil service $WG_SERVICE" scutil --nc start "$WG_SERVICE"
      ;;
    scutil:off)
      if ! has_cmd scutil; then missing_tool "mac" "scutil" "WG stop via scutil"; return 1; fi
      if [ -z "$WG_SERVICE" ]; then result "BAD" "9 WG auto-toggle" "--wg-service required for scutil control"; return 1; fi
      run_cmd "WG stop via scutil service $WG_SERVICE" scutil --nc stop "$WG_SERVICE"
      ;;
    wg-quick:on)
      if ! has_cmd wg-quick; then missing_tool "mac" "wg-quick" "WG start via wg-quick"; return 1; fi
      if [ -z "$WG_QUICK_NAME" ]; then result "BAD" "9 WG auto-toggle" "--wg-quick-name required for wg-quick control"; return 1; fi
      run_cmd "WG start via wg-quick $WG_QUICK_NAME" wg-quick up "$WG_QUICK_NAME"
      ;;
    wg-quick:off)
      if ! has_cmd wg-quick; then missing_tool "mac" "wg-quick" "WG stop via wg-quick"; return 1; fi
      if [ -z "$WG_QUICK_NAME" ]; then result "BAD" "9 WG auto-toggle" "--wg-quick-name required for wg-quick control"; return 1; fi
      run_cmd "WG stop via wg-quick $WG_QUICK_NAME" wg-quick down "$WG_QUICK_NAME"
      ;;
    cmd:on)
      if [ -z "$WG_UP_CMD" ]; then result "BAD" "9 WG auto-toggle" "--wg-up-cmd required for cmd control"; return 1; fi
      run_sh "WG start via explicit command" "$WG_UP_CMD"
      ;;
    cmd:off)
      if [ -z "$WG_DOWN_CMD" ]; then result "BAD" "9 WG auto-toggle" "--wg-down-cmd required for cmd control"; return 1; fi
      run_sh "WG stop via explicit command" "$WG_DOWN_CMD"
      ;;
    *)
      result "BAD" "9 WG auto-toggle" "unsupported WG control action: $backend $action"
      return 1
      ;;
  esac
}

wg_set_state() {
  desired="$1"
  current="$(wg_detect_state)"
  if [ "$current" = "$desired" ]; then
    result "OK" "9 WG auto-toggle" "WG already $desired"
    return 0
  fi

  if wg_control_action "$desired"; then
    progress_sleep "waiting for WG $desired settle" "$WG_SETTLE_SECONDS"
    after="$(wg_detect_state)"
    if [ "$after" = "$desired" ]; then
      result "OK" "9 WG auto-toggle" "WG switched to $desired"
      return 0
    fi
    result "WARN" "9 WG auto-toggle" "WG control command ran, but detected state is $after, expected $desired"
    return 1
  fi
  return 1
}

restore_wg_state() {
  [ "$AUTO_TOGGLE_WG" = "1" ] || return 0
  [ "$WG_RESTORE_DONE" = "0" ] || return 0
  WG_RESTORE_DONE=1

  case "$RESTORE_WG" in
    none) return 0 ;;
    initial) target="$INITIAL_WG_STATE" ;;
    on|off) target="$RESTORE_WG" ;;
    *) target="$INITIAL_WG_STATE" ;;
  esac

  case "$target" in
    on|off)
      section "9 WG auto-toggle restore"
      wg_set_state "$target" >/dev/null 2>&1 || true
      ;;
  esac
}

resolve_host() {
  host="$1"
  if [ -z "$host" ]; then
    return 1
  fi
  if has_cmd dscacheutil; then
    dscacheutil -q host -a name "$host" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}'
    return 0
  fi
  if has_cmd nslookup; then
    nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2; exit}'
    return 0
  fi
  return 1
}

ping_host() {
  segment="$1"
  label="$2"
  host="$3"
  count="${4:-$COUNT}"

  if [ -z "$host" ]; then
    result "SKIP" "$segment" "$label: target not set"
    return 0
  fi
  if ! has_cmd ping; then
    missing_tool "mac" "ping" "$label latency/loss"
    return 0
  fi

  if run_cmd "$label ping $host" ping -c "$count" "$host"; then
    result "OK" "$segment" "$label: ping $host completed"
  else
    result "BAD" "$segment" "$label: ping $host failed or has severe loss"
  fi
}

long_ping_probe() {
  segment="$1"
  label="$2"
  host="$3"
  size="${4:-56}"

  if [ -z "$host" ]; then
    result "SKIP" "$segment" "$label: target not set"
    return 0
  fi
  if ! has_cmd ping; then
    missing_tool "mac" "ping" "$label long loss/jitter check"
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/wgdiag-long-ping.XXXXXX" 2>/dev/null || printf "%s\n" "${TMPDIR:-/tmp}/wgdiag-long-ping.$$")"
  log_raw ""
  log_raw "--- $label long ping $host size=$size count=$LOSS_COUNT interval=$LOSS_INTERVAL ---"
  log_raw "# ping -c $LOSS_COUNT -i $LOSS_INTERVAL -s $size $host"
  expected="$(awk -v c="$LOSS_COUNT" -v i="$LOSS_INTERVAL" 'BEGIN {v=c*i; if (v < 1) v=1; printf "%.0f", v}' 2>/dev/null || printf "%s" "$LOSS_COUNT")"
  ping -c "$LOSS_COUNT" -i "$LOSS_INTERVAL" -s "$size" "$host" > "$tmp" 2>&1 &
  ping_pid=$!
  progress_wait "$label long ping" "$ping_pid" "$expected"
  wait "$ping_pid"
  rc=$?
  if [ -f "$tmp" ]; then
    redact_stream < "$tmp" >> "$RAW_LOG"
    stats="$(awk '
    /packets transmitted/ {
      tx=$1; rx=$4; loss=$7
    }
    /round-trip|rtt/ {
      split($0, a, "="); split(a[2], b, "/")
      min=b[1]; avg=b[2]; max=b[3]; std=b[4]
      gsub(/[[:space:]]|ms/, "", min)
      gsub(/[[:space:]]|ms/, "", avg)
      gsub(/[[:space:]]|ms/, "", max)
      gsub(/[[:space:]]|ms/, "", std)
    }
    END {
      printf "tx=%s rx=%s loss=%s min=%s avg=%s max=%s stddev=%s", tx, rx, loss, min, avg, max, std
    }
  ' "$tmp")"
  else
    stats=""
    log_raw "long ping temporary output missing"
  fi
  loss_pct="$(printf "%s" "$stats" | sed -n 's/.*loss=\([0-9.]*\)%.*/\1/p')"
  max_ms="$(printf "%s" "$stats" | sed -n 's/.*max=\([0-9.]*\).*/\1/p')"
  std_ms="$(printf "%s" "$stats" | sed -n 's/.*stddev=\([0-9.]*\).*/\1/p')"
  rm -f "$tmp" 2>/dev/null || true
  log_raw "# exit=$rc"

  status="OK"
  note="$label: $stats"
  if [ -z "$stats" ] || ! printf "%s" "$stats" | grep -q 'tx=[0-9]'; then
    status="WARN"
    note="$label: no parseable ping statistics rc=$rc"
  elif [ "$rc" -ne 0 ]; then
    status="WARN"
  fi
  if [ -n "$loss_pct" ] && awk -v n="$loss_pct" 'BEGIN {exit !(n > 0)}'; then
    status="WARN"
  fi
  if [ -n "$max_ms" ] && awk -v n="$max_ms" 'BEGIN {exit !(n > 500)}'; then
    status="WARN"
    note="$note; spike>500ms"
  fi
  if [ -n "$std_ms" ] && awk -v n="$std_ms" 'BEGIN {exit !(n > 100)}'; then
    status="WARN"
    note="$note; high_jitter"
  fi
  result "$status" "$segment" "$note"
}

curl_probe() {
  segment="$1"
  label="$2"
  url="$3"

  if ! has_cmd curl; then
    missing_tool "mac" "curl" "$label HTTP/TLS timing"
    return 0
  fi

  if run_cmd "$label curl $url" curl --noproxy '*' -4 -L -sS -o /dev/null --connect-timeout 5 --max-time 15 -w "http_code=%{http_code} remote_ip=%{remote_ip} time_connect=%{time_connect} time_starttransfer=%{time_starttransfer} time_total=%{time_total}\n" "$url"; then
    result "OK" "$segment" "$label: HTTP/TLS probe completed"
  else
    result "WARN" "$segment" "$label: HTTP/TLS probe failed"
  fi
}

tcp_probe() {
  segment="$1"
  label="$2"
  host="$3"
  port="$4"

  if [ -z "$host" ] || [ -z "$port" ]; then
    result "SKIP" "$segment" "$label: host/port not set"
    return 0
  fi
  if has_cmd nc; then
    if run_cmd "$label TCP $host:$port" nc -vz -G 5 "$host" "$port"; then
      result "OK" "$segment" "$label: TCP $host:$port reachable"
    else
      result "WARN" "$segment" "$label: TCP $host:$port not reachable"
    fi
  elif has_cmd curl; then
    if run_cmd "$label TCP via curl $host:$port" curl --noproxy '*' -vIs --connect-timeout 5 --max-time 8 "http://$host:$port/"; then
      result "OK" "$segment" "$label: TCP-ish curl probe completed"
    else
      result "WARN" "$segment" "$label: TCP-ish curl probe failed"
    fi
  else
    missing_tool "mac" "nc" "$label TCP connect"
  fi
}

udp_probe() {
  segment="$1"
  label="$2"
  host="$3"
  port="$4"

  if [ -z "$host" ] || [ -z "$port" ]; then
    result "SKIP" "$segment" "$label: host/port not set"
    return 0
  fi
  if ! has_cmd nc; then
    missing_tool "mac" "nc" "$label UDP reachability best-effort"
    return 0
  fi

  if run_cmd "$label UDP $host:$port" nc -uvz -w 5 "$host" "$port"; then
    result "OK" "$segment" "$label: UDP $host:$port best-effort probe returned success"
  else
    result "WARN" "$segment" "$label: UDP $host:$port probe inconclusive or failed"
  fi
}

route_probe() {
  segment="$1"
  label="$2"
  host="$3"
  if [ -z "$host" ]; then
    result "SKIP" "$segment" "$label: target not set"
    return 0
  fi
  if ! has_cmd route; then
    missing_tool "mac" "route" "$label route lookup"
    return 0
  fi
  if run_cmd "$label route get $host" route get "$host"; then
    result "OK" "$segment" "$label: route lookup completed"
  else
    result "WARN" "$segment" "$label: route lookup failed"
  fi
}

traceroute_probe() {
  segment="$1"
  label="$2"
  host="$3"
  if [ -z "$host" ]; then
    result "SKIP" "$segment" "$label: target not set"
    return 0
  fi
  if ! has_cmd traceroute; then
    missing_tool "mac" "traceroute" "$label path trace"
    return 0
  fi

  tmp="$OUT_DIR/.traceroute.$$"
  log_raw ""
  log_raw "--- $label traceroute $host ---"
  log_raw "# traceroute -m 12 -w 1 $host"
  traceroute -m 12 -w 1 "$host" > "$tmp" 2>&1 &
  trace_pid=$!
  progress_wait "$label traceroute" "$trace_pid" 12
  wait "$trace_pid"
  rc=$?
  redact_stream < "$tmp" >> "$RAW_LOG"
  last_any_hop="$(awk '/^[[:space:]]*[0-9]+[[:space:]]/ {hop=$1} END {print hop}' "$tmp" 2>/dev/null)"
  last_responding_hop="$(awk '
    /^[[:space:]]*[0-9]+[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
      gsub(/[[:space:]*]/, "", line)
      if (line != "") hop=$1
    }
    END {print hop}
  ' "$tmp" 2>/dev/null)"
  rm -f "$tmp" 2>/dev/null || true
  log_raw "# exit=$rc"

  if [ "$rc" -eq 0 ] && [ -n "$last_responding_hop" ] && [ "$last_responding_hop" = "$last_any_hop" ]; then
    result "OK" "$segment" "$label: traceroute completed, hops=$last_responding_hop"
  elif [ -n "$last_responding_hop" ]; then
    result "WARN" "$segment" "$label: traceroute partial, last_responding_hop=$last_responding_hop"
  else
    result "WARN" "$segment" "$label: traceroute failed"
  fi
}

bytes_per_sec_to_mbps() {
  bps="$1"
  awk -v bps="$bps" 'BEGIN { if (bps == "" || bps <= 0) printf "0.00"; else printf "%.2f", (bps * 8) / 1000000 }'
}

speed_curl_probe() {
  label="$1"
  url="$2"

  if [ -z "$url" ]; then
    result "SKIP" "7 Speed tests" "$label: speed URL not set"
    return 0
  fi
  if ! has_cmd curl; then
    missing_tool "mac" "curl" "$label speed download"
    return 0
  fi

  tmp="$OUT_DIR/.speed-curl.$$"
  log_raw ""
  log_raw "--- $label speed curl $url ---"
  log_raw "# curl --noproxy '*' -4 -L -sS -o /dev/null --connect-timeout 5 --max-time $SPEED_SECONDS -w bytes=%{size_download} speed_Bps=%{speed_download} time=%{time_total} http_code=%{http_code} remote_ip=%{remote_ip} $url"
  curl --noproxy '*' -4 -L -sS -o /dev/null --connect-timeout 5 --max-time "$SPEED_SECONDS" \
    -w "bytes=%{size_download} speed_Bps=%{speed_download} time=%{time_total} http_code=%{http_code} remote_ip=%{remote_ip}\n" \
    "$url" > "$tmp" 2>&1 &
  curl_pid=$!
  progress_wait "$label speed download" "$curl_pid" "$SPEED_SECONDS"
  wait "$curl_pid"
  rc=$?
  redact_stream < "$tmp" >> "$RAW_LOG"
  line="$(tail -n 1 "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" 2>/dev/null || true
  log_raw "# exit=$rc"

  bytes="$(printf "%s" "$line" | sed -n 's/.*bytes=\([0-9][0-9]*\).*/\1/p')"
  speed_bps="$(printf "%s" "$line" | sed -n 's/.*speed_Bps=\([0-9.][0-9.]*\).*/\1/p')"
  time_total="$(printf "%s" "$line" | sed -n 's/.*time=\([0-9.][0-9.]*\).*/\1/p')"
  http_code="$(printf "%s" "$line" | sed -n 's/.*http_code=\([0-9][0-9]*\).*/\1/p')"

  if [ -n "$bytes" ] && [ "${bytes:-0}" -gt 0 ] && [ -n "$speed_bps" ]; then
    mbps="$(bytes_per_sec_to_mbps "$speed_bps")"
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 28 ]; then
      result "OK" "7 Speed tests" "$label: ${mbps} Mbps, bytes=$bytes, time=${time_total:-unknown}s, http=${http_code:-unknown}"
    else
      result "WARN" "7 Speed tests" "$label: partial ${mbps} Mbps, bytes=$bytes, curl_exit=$rc"
    fi
    return 0
  fi

  result "WARN" "7 Speed tests" "$label: HTTP speed test failed, curl_exit=$rc"
}

iperf_probe() {
  label="$1"
  host="$2"
  port="$3"

  if [ -z "$host" ]; then
    result "SKIP" "7 Speed tests" "$label: iperf host not set"
    return 0
  fi
  if ! has_cmd iperf3; then
    missing_tool "mac" "iperf3" "$label iperf3 client test"
    return 0
  fi

  tmp="$OUT_DIR/.iperf.$$"
  log_raw ""
  log_raw "--- $label iperf3 $host:$port ---"
  log_raw "# iperf3 -c $host -p $port -t $SPEED_SECONDS"
  iperf3 -c "$host" -p "$port" -t "$SPEED_SECONDS" > "$tmp" 2>&1 &
  iperf_pid=$!
  progress_wait "$label iperf3" "$iperf_pid" "$SPEED_SECONDS"
  wait "$iperf_pid"
  rc=$?
  redact_stream < "$tmp" >> "$RAW_LOG"
  summary_line="$(awk '/receiver/ {line=$0} END {print line}' "$tmp" 2>/dev/null)"
  rm -f "$tmp" 2>/dev/null || true
  log_raw "# exit=$rc"

  if [ "$rc" -eq 0 ]; then
    result "OK" "7 Speed tests" "$label: iperf3 completed; ${summary_line:-see raw.log}"
  else
    case "$summary_line" in
      *"Connection refused"*|*"unable to connect"*)
        result "WARN" "7 Speed tests" "$label: iperf3 server not reachable on $host:$port"
        ;;
      *)
        result "WARN" "7 Speed tests" "$label: iperf3 failed on $host:$port"
        ;;
    esac
  fi
}

ssh_router_cmd() {
  remote_cmd="$1"
  ssh_opts="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
  if [ -n "$SSH_KEY" ]; then
    # shellcheck disable=SC2086
    ssh $ssh_opts -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" -i "$SSH_KEY" "$ROUTER" "$remote_cmd"
  else
    # shellcheck disable=SC2086
    ssh $ssh_opts -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" "$ROUTER" "$remote_cmd"
  fi
}

router_iperf_probe() {
  host="$1"
  port="$2"

  if [ "$ROUTER_IPERF_SERVER" != "1" ]; then
    iperf_probe "Mac -> router iperf3" "$host" "$port"
    return 0
  fi
  if [ -z "$ROUTER" ]; then
    result "SKIP" "7 Speed tests" "Mac -> router iperf3: --router is empty"
    return 0
  fi
  if [ -z "$host" ]; then
    result "SKIP" "7 Speed tests" "Mac -> router iperf3: router host not set"
    return 0
  fi
  if ! has_cmd ssh; then
    missing_tool "mac" "ssh" "temporary OpenWrt iperf3 server"
    return 0
  fi
  if ! has_cmd iperf3; then
    missing_tool "mac" "iperf3" "Mac -> router iperf3 client test"
    return 0
  fi

  log_raw ""
  log_raw "--- Start temporary OpenWrt iperf3 server ---"
  start_out="$OUT_DIR/.router-iperf-start.$$"
  ssh_router_cmd "sh -c 'command -v iperf3 >/dev/null 2>&1 || exit 127; log=/tmp/wgdiag-iperf3-\$\$.log; if command -v nohup >/dev/null 2>&1; then nohup iperf3 -s -1 -p $port >\"\$log\" 2>&1 & else iperf3 -s -1 -p $port >\"\$log\" 2>&1 & fi; pid=\$!; printf \"pid=%s log=%s\\n\" \"\$pid\" \"\$log\"'" > "$start_out" 2>&1
  start_rc=$?
  redact_stream < "$start_out" >> "$RAW_LOG"
  if [ "$start_rc" -ne 0 ]; then
    rm -f "$start_out" 2>/dev/null || true
    result "WARN" "7 Speed tests" "Mac -> router iperf3: failed to start temporary server on OpenWrt"
    return 0
  fi
  router_iperf_pid="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$start_out" | head -n1)"
  router_iperf_log="$(sed -n 's/.*log=\([^ ]*\).*/\1/p' "$start_out" | head -n1)"
  rm -f "$start_out" 2>/dev/null || true

  progress_sleep "waiting for OpenWrt iperf3 server" 1

  iperf_probe "Mac -> router iperf3" "$host" "$port"

  if [ -n "${router_iperf_pid:-}" ]; then
    ssh_router_cmd "sh -c 'kill $router_iperf_pid >/dev/null 2>&1 || true; [ -n \"$router_iperf_log\" ] && cat \"$router_iperf_log\" 2>/dev/null || true; [ -n \"$router_iperf_log\" ] && rm -f \"$router_iperf_log\" 2>/dev/null || true'" >> "$RAW_LOG" 2>&1 || true
  fi
}

ssh_stream_probe() {
  if [ -z "$ROUTER" ]; then
    result "SKIP" "8 Loss/Jitter" "SSH stream test: --router is empty"
    return 0
  fi
  if ! has_cmd ssh; then
    missing_tool "mac" "ssh" "SSH stream stall check"
    return 0
  fi

  tmp="$OUT_DIR/.ssh-stream.$$"
  log_raw ""
  log_raw "--- SSH stream test router ---"
  log_raw "# ssh router sh -c 'i=1; while [ \$i -le 400 ]; do printf ...; i=\$((i+1)); done'"
  start_epoch="$(date +%s 2>/dev/null || echo 0)"
  ssh_router_cmd "sh -c 'i=1; while [ \$i -le 400 ]; do printf \"%04d %s\\n\" \"\$i\" \"\$(date +%s 2>/dev/null || echo 0)\"; i=\$((i+1)); done'" > "$tmp" 2>&1 &
  ssh_stream_pid=$!
  progress_wait "SSH stream test" "$ssh_stream_pid" 8
  wait "$ssh_stream_pid"
  rc=$?
  end_epoch="$(date +%s 2>/dev/null || echo 0)"
  redact_stream < "$tmp" >> "$RAW_LOG"
  lines="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  rm -f "$tmp" 2>/dev/null || true
  elapsed=$((end_epoch - start_epoch))
  log_raw "# exit=$rc elapsed=${elapsed}s lines=${lines:-0}"

  if [ "$rc" -eq 0 ] && [ "${lines:-0}" -ge 400 ]; then
    result "OK" "8 Loss/Jitter" "SSH stream test: 400 lines received in ${elapsed}s"
  else
    result "WARN" "8 Loss/Jitter" "SSH stream test: rc=$rc lines=${lines:-0} elapsed=${elapsed}s"
  fi
}

mac_loss_checks() {
  section "8 Loss/Jitter long checks"
  long_ping_probe "8 Loss/Jitter" "WG endpoint small packets" "$WG_SERVER" "56"
  first_lan=""
  for target in $(pick_lan_targets); do
    first_lan="$target"
    break
  done
  long_ping_probe "8 Loss/Jitter" "Router small packets" "$first_lan" "56"
  long_ping_probe "8 Loss/Jitter" "Router large packets" "$first_lan" "1200"
  long_ping_probe "8 Loss/Jitter" "RF target small packets" "$RF_TARGET" "56"
  long_ping_probe "8 Loss/Jitter" "Foreign target small packets" "$FOREIGN_TARGET" "56"
  ssh_stream_probe
}

detect_default_gateway() {
  if has_cmd route; then
    route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'
  fi
}

detect_wg_iface() {
  if [ "$WG_IFACE" != "auto" ] && [ -n "$WG_IFACE" ]; then
    printf "%s" "$WG_IFACE"
    return 0
  fi
  if has_cmd ifconfig; then
    ifconfig 2>/dev/null | awk -F: '/^utun[0-9]+:/ {print $1; exit}'
  fi
}

pick_lan_targets() {
  if [ -n "$LAN_TARGET" ]; then
    printf "%s\n" "$LAN_TARGET"
  else
    printf "%s\n" "192.168.0.1"
  fi
}

mtu_payload_ok_mac() {
  host="$1"
  size="$2"
  ping -D -c 1 -W 2000 -s "$size" "$host" >/dev/null 2>&1
}

mtu_probe_mac() {
  label="$1"
  host="$2"

  if [ -z "$host" ]; then
    result "SKIP" "5 MTU/MSS" "$label: target not set"
    return 0
  fi
  if ! has_cmd ping; then
    missing_tool "mac" "ping" "$label PMTU probe"
    return 0
  fi

  low="$MTU_MIN"
  high="$MTU_MAX"
  best=""

  while [ "$low" -le "$high" ]; do
    mid=$(((low + high) / 2))
    if mtu_payload_ok_mac "$host" "$mid"; then
      best="$mid"
      low=$((mid + 1))
    else
      high=$((mid - 1))
    fi
  done

  log_raw ""
  log_raw "--- MTU probe mac $label $host ---"
  log_raw "payload_min=$MTU_MIN payload_max=$MTU_MAX best_payload=${best:-none}"

  if [ -n "$best" ]; then
    recommended=$((best + 28))
    result "OK" "5 MTU/MSS" "$label: largest no-fragment IPv4 ping payload=$best, approx path MTU=$recommended"
    if [ "$recommended" -lt 1380 ]; then
      result "WARN" "5 MTU/MSS" "$label: low PMTU suggests WG MTU/MSS blackhole risk"
    fi
  else
    result "BAD" "5 MTU/MSS" "$label: no payload in $MTU_MIN-$MTU_MAX passed with DF; blackhole likely or ICMP blocked"
  fi
}

write_header() {
  {
    printf "WireGuard/VLESS/OpenWrt chain diagnostics\n"
    printf "=========================================\n\n"
    printf "time=%s\n" "$(date +'%F %T %z' 2>/dev/null || date)"
    printf "out_dir=%s\n" "$OUT_DIR"
    printf "profile=%s\n" "$PROFILE_NAME"
    printf "progress_enabled=%s\n" "$PROGRESS_ENABLED"
    printf "router=%s\n" "${ROUTER:-<not set>}"
    printf "wg_server=%s\n" "${WG_SERVER:-<not set>}"
    printf "wg_port=%s\n" "$WG_PORT"
    printf "wg_iface=%s\n" "$WG_IFACE"
    printf "rf_target=%s\n" "$RF_TARGET"
    printf "foreign_target=%s\n" "$FOREIGN_TARGET"
    printf "vps_host=%s\n" "${VPS_HOST:-<not set>}"
    printf "speed_enabled=%s\n" "$SPEED_ENABLED"
    printf "speed_seconds=%s\n" "$SPEED_SECONDS"
    printf "speed_url_rf=%s\n" "${SPEED_URL_RF:-<not set>}"
    printf "speed_url_foreign=%s\n" "${SPEED_URL_FOREIGN:-<not set>}"
    printf "iperf_host=%s\n" "${IPERF_HOST:-<not set>}"
    printf "iperf_port=%s\n" "$IPERF_PORT"
    printf "router_iperf_server=%s\n" "$ROUTER_IPERF_SERVER"
    printf "auto_toggle_wg=%s\n" "$AUTO_TOGGLE_WG"
    printf "wg_control=%s\n" "$WG_CONTROL"
    printf "wg_service=%s\n" "${WG_SERVICE:-<not set>}"
    printf "wg_quick_name=%s\n" "${WG_QUICK_NAME:-<not set>}"
    printf "wg_settle_seconds=%s\n" "$WG_SETTLE_SECONDS"
    printf "restore_wg=%s\n" "$RESTORE_WG"
  } >> "$SUMMARY"
  log_raw "time=$(date +'%F %T %z' 2>/dev/null || date)"
  log_raw "script=$SCRIPT_NAME"
}

show_run_banner() {
  [ "$PROGRESS_ENABLED" = "1" ] || return 0
  printf "\nStarting diagnostics\n"
  printf "====================\n"
  printf "profile: %s\n" "$PROFILE_NAME"
  printf "report: %s\n" "$OUT_DIR"
  printf "router: %s\n" "${ROUTER:-<none>}"
  printf "wg endpoint: %s:%s\n" "${WG_SERVER:-<none>}" "$WG_PORT"
  printf "targets: lan=%s rf=%s foreign=%s\n" "${LAN_TARGET:-<none>}" "$RF_TARGET" "$FOREIGN_TARGET"
  if [ "$AUTO_TOGGLE_WG" = "1" ]; then
    printf "WG auto-toggle: enabled, restore=%s\n" "$RESTORE_WG"
  else
    printf "WG auto-toggle: disabled\n"
  fi
}

mac_tool_checks() {
  section "6 Missing tools"
  check_tool "mac" "sh" "script execution" >/dev/null
  check_tool "mac" "ssh" "OpenWrt remote diagnostics" >/dev/null
  check_tool "mac" "ping" "latency/loss and PMTU probes" >/dev/null
  check_tool "mac" "route" "route lookup" >/dev/null
  check_tool "mac" "netstat" "routing snapshot" >/dev/null
  check_tool "mac" "ifconfig" "interface snapshot and utun detection" >/dev/null
  check_tool "mac" "scutil" "DNS resolver snapshot" >/dev/null
  check_tool "mac" "dscacheutil" "host resolution details" >/dev/null
  check_tool "mac" "nc" "TCP/UDP connect probes" >/dev/null
  check_tool "mac" "curl" "HTTP/TLS timing and public IP probes" >/dev/null
  check_tool "mac" "traceroute" "path trace to WG/VPS targets" >/dev/null
  check_tool "mac" "iperf3" "optional speed tests" >/dev/null
}

mac_snapshot() {
  section "0 Mac/Hotspot snapshot"
  run_sh "macOS version" 'sw_vers 2>&1 || true; uname -a 2>&1 || true'
  run_sh "default route" 'route -n get default 2>&1 || true'
  run_sh "interfaces" 'ifconfig 2>&1 || true'
  run_sh "routes" 'netstat -rn 2>&1 || true'
  run_sh "DNS resolvers" 'scutil --dns 2>&1 || true'
  run_sh "utun interfaces" 'ifconfig 2>/dev/null | awk -F: "/^utun[0-9]+:/ {print \$1}"'
  run_sh "Wi-Fi/hotspot hints" '/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>&1 || networksetup -listallhardwareports 2>&1 || true'
  run_sh "macOS proxy environment" 'env | grep -Ei "^(all|http|https|no)_proxy=" 2>&1 || true; scutil --proxy 2>&1 || true'

  wg_detected="$(detect_wg_iface)"
  if [ -n "$wg_detected" ]; then
    result "OK" "0 Mac/Hotspot" "detected WireGuard-like interface: $wg_detected"
  else
    result "WARN" "0 Mac/Hotspot" "no utun/WG interface detected automatically"
  fi
}

mac_hotspot_checks() {
  section "0 Mac/Hotspot checks"
  gw="$(detect_default_gateway)"
  if [ -n "$gw" ]; then
    result "OK" "0 Mac/Hotspot" "default gateway: $gw"
    ping_host "0 Mac/Hotspot" "default gateway" "$gw" 5
  else
    result "WARN" "0 Mac/Hotspot" "default gateway not detected"
  fi
  ping_host "0 Mac/Hotspot" "public resolver 1.1.1.1" "1.1.1.1" "$COUNT"
  ping_host "0 Mac/Hotspot" "public resolver 9.9.9.9" "9.9.9.9" "$COUNT"
  curl_probe "0 Mac/Hotspot" "current public IP" "https://ifconfig.me"
}

mac_wg_checks() {
  section "1 Mac->WG server"
  if [ -z "$WG_SERVER" ]; then
    result "SKIP" "1 Mac->WG" "--wg-server not set; public WG endpoint checks skipped"
    return 0
  fi

  resolved="$(resolve_host "$WG_SERVER")"
  if [ -n "$resolved" ]; then
    result "OK" "1 Mac->WG" "$WG_SERVER resolves to $resolved"
  else
    result "WARN" "1 Mac->WG" "$WG_SERVER did not resolve through available local tools"
  fi

  route_probe "1 Mac->WG" "WG endpoint" "$WG_SERVER"
  ping_host "1 Mac->WG" "WG endpoint" "$WG_SERVER" "$COUNT"
  udp_probe "1 Mac->WG" "WG endpoint" "$WG_SERVER" "$WG_PORT"
  traceroute_probe "1 Mac->WG" "WG endpoint" "$WG_SERVER"
}

mac_tunnel_checks() {
  section "2 WG/OpenWrt tunnel from Mac"
  for target in $(pick_lan_targets); do
    route_probe "2 WG/OpenWrt" "LAN/WG target $target" "$target"
    ping_host "2 WG/OpenWrt" "LAN/WG target" "$target" "$COUNT"
    traceroute_probe "2 WG/OpenWrt" "LAN/WG target" "$target"
  done
}

mac_split_checks() {
  section "3 Split->RF from Mac"
  route_probe "3 Split->RF" "RF target $RF_TARGET" "$RF_TARGET"
  resolved="$(resolve_host "$RF_TARGET")"
  [ -n "$resolved" ] && result "OK" "3 Split->RF" "$RF_TARGET resolves to $resolved" || result "WARN" "3 Split->RF" "$RF_TARGET resolve failed"
  ping_host "3 Split->RF" "RF target" "$RF_TARGET" "$COUNT"
  traceroute_probe "3 Split->RF" "RF target" "$RF_TARGET"
  curl_probe "3 Split->RF" "RF target HTTPS" "https://$RF_TARGET"

  section "4 Split->VPS/Foreign from Mac"
  route_probe "4 Split->VPS/Foreign" "foreign target $FOREIGN_TARGET" "$FOREIGN_TARGET"
  resolved="$(resolve_host "$FOREIGN_TARGET")"
  [ -n "$resolved" ] && result "OK" "4 Split->VPS/Foreign" "$FOREIGN_TARGET resolves to $resolved" || result "WARN" "4 Split->VPS/Foreign" "$FOREIGN_TARGET resolve failed"
  ping_host "4 Split->VPS/Foreign" "foreign target" "$FOREIGN_TARGET" "$COUNT"
  traceroute_probe "4 Split->VPS/Foreign" "foreign target" "$FOREIGN_TARGET"
  curl_probe "4 Split->VPS/Foreign" "foreign target HTTPS" "https://$FOREIGN_TARGET"
  if [ -n "$VPS_HOST" ]; then
    route_probe "4 Split->VPS/Foreign" "VPS $VPS_HOST" "$VPS_HOST"
    ping_host "4 Split->VPS/Foreign" "VPS host" "$VPS_HOST" "$COUNT"
    traceroute_probe "4 Split->VPS/Foreign" "VPS host" "$VPS_HOST"
    tcp_probe "4 Split->VPS/Foreign" "VPS SSH" "$VPS_HOST" "22"
  fi
}

mac_mtu_checks() {
  section "5 MTU/MSS from Mac"
  first_lan=""
  for target in $(pick_lan_targets); do
    first_lan="$target"
    break
  done
  mtu_probe_mac "LAN/WG target" "$first_lan"
  mtu_probe_mac "RF target" "$RF_TARGET"
  mtu_probe_mac "foreign target" "$FOREIGN_TARGET"
}

mac_speed_checks() {
  section "7 Speed tests from Mac"
  if [ "$SPEED_ENABLED" != "1" ]; then
    result "SKIP" "7 Speed tests" "speed tests disabled by --no-speed"
    return 0
  fi

  speed_curl_probe "Mac/Hotspot/foreign default timed download" "$SPEED_URL_FOREIGN"
  speed_curl_probe "Mac RF timed download" "$SPEED_URL_RF"
  speed_curl_probe "Mac foreign timed download" "$SPEED_URL_FOREIGN"

  first_lan=""
  for target in $(pick_lan_targets); do
    first_lan="$target"
    break
  done
  router_iperf_probe "$first_lan" "$IPERF_PORT"
  iperf_probe "Mac -> iperf host" "$IPERF_HOST" "$IPERF_PORT"
}

mac_public_baseline_checks() {
  section "9 WG off baseline"
  state="$(wg_detect_state)"
  result "OK" "9 WG auto-toggle" "baseline detected WG state: $state"

  mac_snapshot
  mac_hotspot_checks
  mac_wg_checks
  long_ping_probe "9 WG off baseline" "WG endpoint without tunnel" "$WG_SERVER" "56"
  long_ping_probe "9 WG off baseline" "public resolver without tunnel" "1.1.1.1" "56"

  if [ "$SPEED_ENABLED" = "1" ]; then
    section "9 WG off baseline speed"
    speed_curl_probe "WG off foreign timed download" "$SPEED_URL_FOREIGN"
    speed_curl_probe "WG off RF timed download" "$SPEED_URL_RF"
  fi
}

run_full_chain() {
  mac_snapshot
  mac_hotspot_checks
  mac_wg_checks
  mac_tunnel_checks
  mac_split_checks
  mac_mtu_checks
  mac_loss_checks
  mac_speed_checks
  run_openwrt_remote
}

run_auto_toggle_flow() {
  section "9 WG auto-toggle A/B"
  result "WARN" "9 WG auto-toggle" "--auto-toggle-wg is enabled; this run will start/stop local WG on macOS"
  INITIAL_WG_STATE="$(wg_detect_state)"
  result "OK" "9 WG auto-toggle" "initial detected WG state: $INITIAL_WG_STATE"
  trap 'restore_wg_state' EXIT HUP INT TERM

  if wg_set_state off; then
    mac_public_baseline_checks
  else
    result "WARN" "9 WG auto-toggle" "WG-off baseline may be unreliable because WG could not be confirmed off"
    mac_public_baseline_checks
  fi

  if wg_set_state on; then
    section "9 WG on full-chain run"
    run_full_chain
  else
    result "BAD" "9 WG auto-toggle" "cannot confirm WG on; full chain diagnostics skipped"
  fi

  restore_wg_state
}

ssh_base_cmd() {
  if [ -n "$SSH_KEY" ]; then
    printf "%s\n" "ssh -p '$SSH_PORT' -i '$SSH_KEY' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$SSH_KNOWN_HOSTS' '$ROUTER'"
  else
    printf "%s\n" "ssh -p '$SSH_PORT' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$SSH_KNOWN_HOSTS' '$ROUTER'"
  fi
}

run_openwrt_remote() {
  section "2 WG/OpenWrt remote diagnostics"
  if [ -z "$ROUTER" ]; then
    result "SKIP" "2 WG/OpenWrt" "--router is empty; OpenWrt remote diagnostics skipped"
    return 0
  fi
  if ! has_cmd ssh; then
    missing_tool "mac" "ssh" "OpenWrt remote diagnostics"
    return 0
  fi

  remote_tmp="$OUT_DIR/openwrt-remote.log"
  ssh_opts="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
  remote_script="$OUT_DIR/openwrt-remote-script.sh"
  remote_vps_host="${VPS_HOST:-__EMPTY__}"
  remote_speed_url_rf="${SPEED_URL_RF:-__EMPTY__}"
  remote_speed_url_foreign="${SPEED_URL_FOREIGN:-__EMPTY__}"
  remote_iperf_host="${IPERF_HOST:-__EMPTY__}"
  sed -n '/^openwrt_remote_main()/,$p' "$0" > "$remote_script"
  if [ -n "$SSH_KEY" ]; then
    # shellcheck disable=SC2086
    ssh $ssh_opts -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" -i "$SSH_KEY" "$ROUTER" sh -s -- "$RF_TARGET" "$FOREIGN_TARGET" "$remote_vps_host" "$MTU_MIN" "$MTU_MAX" "$SPEED_ENABLED" "$SPEED_SECONDS" "$remote_speed_url_rf" "$remote_speed_url_foreign" "$remote_iperf_host" "$IPERF_PORT" < "$remote_script" > "$remote_tmp" 2>&1 &
  else
    # shellcheck disable=SC2086
    ssh $ssh_opts -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" "$ROUTER" sh -s -- "$RF_TARGET" "$FOREIGN_TARGET" "$remote_vps_host" "$MTU_MIN" "$MTU_MAX" "$SPEED_ENABLED" "$SPEED_SECONDS" "$remote_speed_url_rf" "$remote_speed_url_foreign" "$remote_iperf_host" "$IPERF_PORT" < "$remote_script" > "$remote_tmp" 2>&1 &
  fi
  remote_pid=$!
  remote_expected=$((30 + SPEED_SECONDS * 3))
  progress_wait "OpenWrt remote diagnostics" "$remote_pid" "$remote_expected"
  wait "$remote_pid"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    redact_stream < "$remote_tmp" >> "$RAW_LOG"
    result "BAD" "2 WG/OpenWrt" "SSH remote diagnostics failed for $ROUTER"
    return 0
  fi

  awk '/^__OPENWRT_DIAG_BEGIN__$/ {p=1; next} p {print}' "$remote_tmp" | redact_stream >> "$RAW_LOG"
  awk -F '\t' '/^RESULT\t/ {printf "[%s] %s: %s\n", $2, $3, $4}' "$remote_tmp" >> "$SUMMARY"
  awk -F '\t' '/^MISSING\t/ {printf "openwrt\t%s\t%s\n", $2, $3}' "$remote_tmp" >> "$MISSING_TOOLS"
  awk -F '\t' '/^RESULT\t/ {printf "%s\t%s\t%s\n", $2, $3, $4}' "$remote_tmp" >> "$RESULTS"
  remote_ok="$(awk -F '\t' '$1=="RESULT" && $2=="OK" {c++} END {print c+0}' "$remote_tmp")"
  remote_warn="$(awk -F '\t' '$1=="RESULT" && $2=="WARN" {c++} END {print c+0}' "$remote_tmp")"
  remote_bad="$(awk -F '\t' '$1=="RESULT" && $2=="BAD" {c++} END {print c+0}' "$remote_tmp")"
  remote_skip="$(awk -F '\t' '$1=="RESULT" && $2=="SKIP" {c++} END {print c+0}' "$remote_tmp")"
  OK_COUNT=$((OK_COUNT + remote_ok))
  WARN_COUNT=$((WARN_COUNT + remote_warn))
  BAD_COUNT=$((BAD_COUNT + remote_bad))
  SKIP_COUNT=$((SKIP_COUNT + remote_skip))

  remote_missing="$(awk -F '\t' '/^MISSING\t/ {c++} END {print c+0}' "$remote_tmp")"
  if [ "$remote_missing" -gt 0 ]; then
    result "WARN" "6 Missing tools" "OpenWrt missing $remote_missing tool(s); see missing-tools.txt"
  else
    result "OK" "6 Missing tools" "OpenWrt required/optional tool check completed without missing entries"
  fi
  result "OK" "2 WG/OpenWrt" "SSH remote diagnostics completed for $ROUTER"
}

write_json_summary() {
  [ "$WRITE_JSON" = "1" ] || return 0
  {
    printf "{\n"
    printf "  \"ok\": %s,\n" "$OK_COUNT"
    printf "  \"warn\": %s,\n" "$WARN_COUNT"
    printf "  \"bad\": %s,\n" "$BAD_COUNT"
    printf "  \"skip\": %s,\n" "$SKIP_COUNT"
    printf "  \"out_dir\": \"%s\",\n" "$(printf "%s" "$OUT_DIR" | sed 's/"/\\"/g')"
    printf "  \"summary\": \"%s\",\n" "$(printf "%s" "$SUMMARY" | sed 's/"/\\"/g')"
    printf "  \"raw_log\": \"%s\",\n" "$(printf "%s" "$RAW_LOG" | sed 's/"/\\"/g')"
    printf "  \"missing_tools\": \"%s\",\n" "$(printf "%s" "$MISSING_TOOLS" | sed 's/"/\\"/g')"
    printf "  \"speed_enabled\": %s,\n" "$SPEED_ENABLED"
    printf "  \"speed_seconds\": %s,\n" "$SPEED_SECONDS"
    printf "  \"iperf_host\": \"%s\",\n" "$(printf "%s" "$IPERF_HOST" | sed 's/"/\\"/g')"
    printf "  \"iperf_port\": %s,\n" "$IPERF_PORT"
    printf "  \"router_iperf_server\": %s\n" "$ROUTER_IPERF_SERVER"
    printf "}\n"
  } > "$JSON_SUMMARY"
}

finalize() {
  {
    printf "\n## Totals\n"
    printf "OK=%s WARN=%s BAD=%s SKIP=%s\n" "$OK_COUNT" "$WARN_COUNT" "$BAD_COUNT" "$SKIP_COUNT"
    printf "\nFiles:\n"
    printf "%s\n" "- raw log: $RAW_LOG"
    printf "%s\n" "- missing tools: $MISSING_TOOLS"
    printf "%s\n" "- results: $RESULTS"
  } >> "$SUMMARY"
  write_json_summary

  say ""
  say "Diagnostics finished."
  say "Summary: $SUMMARY"
  say "Raw log: $RAW_LOG"
  say "Missing tools: $MISSING_TOOLS"
  say "Totals: OK=$OK_COUNT WARN=$WARN_COUNT BAD=$BAD_COUNT SKIP=$SKIP_COUNT"
}

if [ "${1:-}" = "__openwrt_remote__" ]; then
  shift
fi

case "${SCRIPT_NAME:-}" in
  wg-vless-chain-diagnostics.sh) ;;
esac

# If this script is piped to OpenWrt as "sh -s -- rf foreign vps mtu_min mtu_max",
# run the remote block only. The local invocation always has initialized OUT_DIR;
# the remote invocation does not need local files and emits tagged TSV/log lines.
if [ "${OUT_DIR_REMOTE_GUARD:-0}" = "1" ]; then
  :
fi

if [ "${REMOTE_OPENWRT_DIAG:-0}" = "1" ]; then
  :
fi

openwrt_remote_main() {
  RF_TARGET_R="${1:-ya.ru}"
  FOREIGN_TARGET_R="${2:-google.com}"
  VPS_HOST_R="${3:-}"
  MTU_MIN_R="${4:-1200}"
  MTU_MAX_R="${5:-1500}"
  SPEED_ENABLED_R="${6:-1}"
  SPEED_SECONDS_R="${7:-10}"
  SPEED_URL_RF_R="${8:-}"
  SPEED_URL_FOREIGN_R="${9:-}"
  IPERF_HOST_R="${10:-}"
  IPERF_PORT_R="${11:-5201}"

  [ "$VPS_HOST_R" = "__EMPTY__" ] && VPS_HOST_R=""
  [ "$SPEED_URL_RF_R" = "__EMPTY__" ] && SPEED_URL_RF_R=""
  [ "$SPEED_URL_FOREIGN_R" = "__EMPTY__" ] && SPEED_URL_FOREIGN_R=""
  [ "$IPERF_HOST_R" = "__EMPTY__" ] && IPERF_HOST_R=""

  printf "%s\n" "__OPENWRT_DIAG_BEGIN__"

  ow_result() {
    printf "RESULT\t%s\t%s\t%s\n" "$1" "$2" "$3"
    printf "[%s] %s: %s\n" "$1" "$2" "$3"
  }
  ow_missing() {
    printf "MISSING\t%s\t%s; install/enable manually\n" "$1" "$2"
    ow_result "SKIP" "6 Missing tools" "OpenWrt: missing $1; skipped: $2; install/enable manually"
  }
  ow_has() {
    command -v "$1" >/dev/null 2>&1
  }
  ow_check_tool() {
    if ow_has "$1"; then
      ow_result "OK" "6 Missing tools" "OpenWrt: $1 is installed"
    else
      ow_missing "$1" "$2"
    fi
  }
  ow_section() {
    printf "\n===== %s =====\n" "$1"
  }
  ow_run() {
    title="$1"
    shift
    ow_section "$title"
    printf "# %s\n" "$*"
    "$@" 2>&1
    printf "# exit=%s\n" "$?"
  }
  ow_sh() {
    title="$1"
    cmd="$2"
    ow_section "$title"
    printf "# %s\n" "$cmd"
    sh -c "$cmd" 2>&1
    printf "# exit=%s\n" "$?"
  }
  ow_ping() {
    segment="$1"
    label="$2"
    host="$3"
    [ -n "$host" ] || { ow_result "SKIP" "$segment" "$label: target not set"; return 0; }
    if ! ow_has ping; then ow_missing "ping" "$label latency/loss"; return 0; fi
    if ping -c 5 -W 2 "$host" >/tmp/wgdiag-ping.$$ 2>&1; then
      cat /tmp/wgdiag-ping.$$
      rm -f /tmp/wgdiag-ping.$$ 2>/dev/null || true
      ow_result "OK" "$segment" "$label: ping $host completed"
    else
      cat /tmp/wgdiag-ping.$$ 2>/dev/null || true
      rm -f /tmp/wgdiag-ping.$$ 2>/dev/null || true
      ow_result "WARN" "$segment" "$label: ping $host failed or has loss"
    fi
  }
  ow_tcp() {
    segment="$1"
    label="$2"
    host="$3"
    port="$4"
    [ -n "$host" ] && [ -n "$port" ] || { ow_result "SKIP" "$segment" "$label: host/port not set"; return 0; }
    if ow_has nc; then
      if nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
        ow_result "OK" "$segment" "$label: TCP $host:$port reachable"
      else
        ow_result "WARN" "$segment" "$label: TCP $host:$port not reachable"
      fi
    elif ow_has curl; then
      if curl -vIs --connect-timeout 5 --max-time 8 "http://$host:$port/" >/dev/null 2>&1; then
        ow_result "OK" "$segment" "$label: TCP-ish curl probe completed"
      else
        ow_result "WARN" "$segment" "$label: TCP-ish curl probe failed"
      fi
    else
      ow_missing "nc" "$label TCP connect"
    fi
  }
  ow_http() {
    segment="$1"
    label="$2"
    url="$3"
    if ow_has curl; then
      if curl -4 -L -sS -o /dev/null --connect-timeout 5 --max-time 15 -w "http_code=%{http_code} remote_ip=%{remote_ip} time_connect=%{time_connect} time_total=%{time_total}\n" "$url"; then
        ow_result "OK" "$segment" "$label: HTTP/TLS probe completed"
      else
        ow_result "WARN" "$segment" "$label: HTTP/TLS probe failed"
      fi
    elif ow_has wget; then
      if wget -T 15 -O /dev/null "$url" >/dev/null 2>&1; then
        ow_result "OK" "$segment" "$label: wget probe completed"
      else
        ow_result "WARN" "$segment" "$label: wget probe failed"
      fi
    else
      ow_missing "curl/wget" "$label HTTP/TLS timing"
    fi
  }
  ow_traceroute() {
    segment="$1"
    label="$2"
    host="$3"
    [ -n "$host" ] || { ow_result "SKIP" "$segment" "$label: target not set"; return 0; }
    if ! ow_has traceroute; then
      ow_missing "traceroute" "$label path trace"
      return 0
    fi
    tmp="/tmp/wgdiag-traceroute.$$"
    traceroute -m 12 -w 1 "$host" > "$tmp" 2>&1
    rc=$?
    cat "$tmp"
    last_any_hop="$(awk '/^[[:space:]]*[0-9]+[[:space:]]/ {hop=$1} END {print hop}' "$tmp" 2>/dev/null)"
    last_responding_hop="$(awk '
      /^[[:space:]]*[0-9]+[[:space:]]/ {
        line=$0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
        gsub(/[[:space:]*]/, "", line)
        if (line != "") hop=$1
      }
      END {print hop}
    ' "$tmp" 2>/dev/null)"
    rm -f "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && [ -n "$last_responding_hop" ] && [ "$last_responding_hop" = "$last_any_hop" ]; then
      ow_result "OK" "$segment" "$label: traceroute completed, hops=$last_responding_hop"
    elif [ -n "$last_responding_hop" ]; then
      ow_result "WARN" "$segment" "$label: traceroute partial, last_responding_hop=$last_responding_hop"
    else
      ow_result "WARN" "$segment" "$label: traceroute failed"
    fi
  }
  ow_bytes_per_sec_to_mbps() {
    bps="$1"
    awk -v bps="$bps" 'BEGIN { if (bps == "" || bps <= 0) printf "0.00"; else printf "%.2f", (bps * 8) / 1000000 }'
  }
  ow_speed_http() {
    label="$1"
    url="$2"
    [ -n "$url" ] || { ow_result "SKIP" "7 Speed tests" "$label: speed URL not set"; return 0; }
    if ow_has curl; then
      tmp="/tmp/wgdiag-speed-curl.$$"
      curl -4 -L -sS -o /dev/null --connect-timeout 5 --max-time "$SPEED_SECONDS_R" \
        -w "bytes=%{size_download} speed_Bps=%{speed_download} time=%{time_total} http_code=%{http_code} remote_ip=%{remote_ip}\n" \
        "$url" > "$tmp" 2>&1
      rc=$?
      cat "$tmp"
      line="$(tail -n 1 "$tmp" 2>/dev/null || true)"
      rm -f "$tmp" 2>/dev/null || true
      bytes="$(printf "%s" "$line" | sed -n 's/.*bytes=\([0-9][0-9]*\).*/\1/p')"
      speed_bps="$(printf "%s" "$line" | sed -n 's/.*speed_Bps=\([0-9.][0-9.]*\).*/\1/p')"
      time_total="$(printf "%s" "$line" | sed -n 's/.*time=\([0-9.][0-9.]*\).*/\1/p')"
      http_code="$(printf "%s" "$line" | sed -n 's/.*http_code=\([0-9][0-9]*\).*/\1/p')"
      if [ -n "$bytes" ] && [ "${bytes:-0}" -gt 0 ] && [ -n "$speed_bps" ]; then
        mbps="$(ow_bytes_per_sec_to_mbps "$speed_bps")"
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 28 ]; then
          ow_result "OK" "7 Speed tests" "$label: ${mbps} Mbps, bytes=$bytes, time=${time_total:-unknown}s, http=${http_code:-unknown}"
        else
          ow_result "WARN" "7 Speed tests" "$label: partial ${mbps} Mbps, bytes=$bytes, curl_exit=$rc"
        fi
      else
        ow_result "WARN" "7 Speed tests" "$label: HTTP speed test failed, curl_exit=$rc"
      fi
    elif ow_has wget; then
      start="$(date +%s 2>/dev/null || echo 0)"
      if wget -T "$SPEED_SECONDS_R" -O /dev/null "$url" 2>&1; then
        ow_result "OK" "7 Speed tests" "$label: wget download completed; exact Mbps unavailable"
      else
        end="$(date +%s 2>/dev/null || echo 0)"
        ow_result "WARN" "7 Speed tests" "$label: wget download failed or timed out after $((end - start))s; exact Mbps unavailable"
      fi
    else
      ow_missing "curl/wget" "$label speed download"
    fi
  }
  ow_iperf() {
    label="$1"
    host="$2"
    port="$3"
    [ -n "$host" ] || { ow_result "SKIP" "7 Speed tests" "$label: iperf host not set"; return 0; }
    if ! ow_has iperf3; then
      ow_missing "iperf3" "$label iperf3 client test"
      return 0
    fi
    tmp="/tmp/wgdiag-iperf.$$"
    iperf3 -c "$host" -p "$port" -t "$SPEED_SECONDS_R" > "$tmp" 2>&1
    rc=$?
    cat "$tmp"
    summary_line="$(awk '/receiver/ {line=$0} END {print line}' "$tmp" 2>/dev/null)"
    rm -f "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      ow_result "OK" "7 Speed tests" "$label: iperf3 completed; ${summary_line:-see raw.log}"
    else
      ow_result "WARN" "7 Speed tests" "$label: iperf3 failed or server not reachable on $host:$port"
    fi
  }
  ow_vless_host_port() {
    if ! ow_has uci; then
      return 1
    fi
    proxy_type="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || true)"
    case "$proxy_type" in
      urltest) links="$(uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n')" ;;
      selector) links="$(uci -q get podkop.main.selector_proxy_links 2>/dev/null | tr ' ' '\n')" ;;
      *) links="$(uci -q get podkop.main.proxy_string 2>/dev/null)" ;;
    esac
    link="$(printf "%s\n" "$links" | sed '/^$/d' | head -n1)"
    [ -n "$link" ] || return 1
    authority="$(printf "%s" "$link" | sed -n 's|^[a-zA-Z0-9+.-]*://[^@]*@\([^/?#]*\).*|\1|p')"
    [ -n "$authority" ] || authority="$(printf "%s" "$link" | sed -n 's|^[a-zA-Z0-9+.-]*://\([^/?#]*\).*|\1|p')"
    [ -n "$authority" ] || return 1
    host="$(printf "%s" "$authority" | sed 's/^\[\([^]]*\)\].*/\1/; s/:.*$//')"
    port="$(printf "%s" "$authority" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p')"
    [ -n "$host" ] || return 1
    printf "%s %s\n" "$host" "$port"
  }
  ow_mtu_payload_ok() {
    host="$1"
    size="$2"
    ping -M do -c 1 -W 2 -s "$size" "$host" >/dev/null 2>&1
  }
  ow_mtu_probe() {
    label="$1"
    host="$2"
    [ -n "$host" ] || { ow_result "SKIP" "5 MTU/MSS" "$label: target not set"; return 0; }
    if ! ow_has ping; then ow_missing "ping" "$label PMTU probe"; return 0; fi
    if ! ping -M do -c 1 -W 1 -s 1200 "$host" >/dev/null 2>&1; then
      ow_result "WARN" "5 MTU/MSS" "$label: DF ping unsupported, ICMP blocked, or payload 1200 fails"
      return 0
    fi
    low="$MTU_MIN_R"
    high="$MTU_MAX_R"
    best=""
    while [ "$low" -le "$high" ]; do
      mid=$(((low + high) / 2))
      if ow_mtu_payload_ok "$host" "$mid"; then
        best="$mid"
        low=$((mid + 1))
      else
        high=$((mid - 1))
      fi
    done
    if [ -n "$best" ]; then
      ow_result "OK" "5 MTU/MSS" "$label: largest no-fragment IPv4 ping payload=$best, approx path MTU=$((best + 28))"
    else
      ow_result "BAD" "5 MTU/MSS" "$label: no payload in $MTU_MIN_R-$MTU_MAX_R passed with DF"
    fi
  }

  ow_section "OpenWrt tools"
  ow_check_tool ip "interface/route/policy snapshots"
  ow_check_tool ss "listener/socket snapshot"
  ow_check_tool uci "read network/firewall/podkop config"
  ow_check_tool ubus "system board snapshot"
  ow_check_tool logread "recent service logs"
  ow_check_tool nft "firewall ruleset snapshot"
  ow_check_tool ping "latency/loss and PMTU probes"
  ow_check_tool nslookup "DNS checks"
  if ow_has curl || ow_has wget; then
    ow_result "OK" "6 Missing tools" "OpenWrt: curl/wget HTTP tool available"
  else
    ow_missing "curl/wget" "HTTP/TLS timing"
  fi
  if ow_has wg || ow_has awg; then
    ow_result "OK" "6 Missing tools" "OpenWrt: wg/awg tool available"
  else
    ow_missing "wg/awg" "WireGuard peer counters"
  fi
  ow_check_tool sing-box "sing-box config check"
  ow_check_tool xray "xray runtime/version checks"
  ow_check_tool traceroute "path trace from router"
  ow_check_tool iperf3 "optional speed tests"

  ow_section "OpenWrt read-only snapshots"
  ow_sh "system board" 'ubus call system board 2>&1 || true; cat /etc/openwrt_release 2>&1 || true'
  ow_sh "interfaces" 'ip addr show 2>&1 || true'
  ow_sh "routes main" 'ip route show table main 2>&1 || true'
  ow_sh "rules" 'ip rule show 2>&1 || true'
  ow_sh "routes all" 'ip route show table all 2>&1 || true'
  ow_sh "listeners" 'ss -lntup 2>&1 || true'
  ow_sh "UCI network/firewall/podkop" 'uci show network 2>&1 || true; uci show firewall 2>&1 || true; uci show podkop 2>&1 || true'
  ow_sh "WG/AWG show" 'wg show 2>&1 || true; awg show 2>&1 || true'
  ow_sh "nft podkop/tproxy rules" 'nft list ruleset 2>&1 | grep -Ei "podkop|sing|tproxy|mark|dns|redirect" -C 3 || true'
  ow_sh "podkop/sing-box logs" 'logread -e podkop 2>&1 | tail -n 160 || true; logread -e sing-box 2>&1 | tail -n 160 || true'

  ow_section "OpenWrt runtime checks"
  if [ -x /etc/init.d/podkop ] && /etc/init.d/podkop status >/dev/null 2>&1; then
    ow_result "OK" "2 WG/OpenWrt" "Podkop init status reports running"
  else
    if ps w 2>/dev/null | grep -Eq "[s]ing-box|[p]odkop|[x]ray"; then
      ow_result "WARN" "2 WG/OpenWrt" "Podkop init not confirmed, but proxy process exists"
    else
      ow_result "BAD" "2 WG/OpenWrt" "Podkop/proxy process not detected"
    fi
  fi
  if ow_has sing-box && [ -s /etc/sing-box/config.json ]; then
    if ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
      ow_result "OK" "2 WG/OpenWrt" "sing-box config check passed"
    else
      ow_result "WARN" "2 WG/OpenWrt" "sing-box config check failed"
    fi
  else
    ow_result "SKIP" "2 WG/OpenWrt" "sing-box config check unavailable"
  fi
  if ip rule show 2>/dev/null | grep -Eqi 'podkop|tproxy|fwmark|0x2023|mark'; then
    ow_result "OK" "2 WG/OpenWrt" "policy rules contain podkop/tproxy/mark evidence"
  else
    ow_result "WARN" "2 WG/OpenWrt" "policy rules do not show podkop/tproxy/mark evidence"
  fi

  hp="$(ow_vless_host_port || true)"
  vhost="$(printf "%s" "$hp" | awk '{print $1}')"
  vport="$(printf "%s" "$hp" | awk '{print $2}')"
  if [ -n "$vhost" ]; then
    ow_result "OK" "4 Split->VPS/Foreign" "extracted VLESS host from Podkop: $vhost"
    ow_ping "4 Split->VPS/Foreign" "VLESS host" "$vhost"
    ow_tcp "4 Split->VPS/Foreign" "VLESS endpoint" "$vhost" "$vport"
  else
    ow_result "WARN" "4 Split->VPS/Foreign" "could not extract VLESS endpoint from Podkop UCI"
  fi

  ow_section "OpenWrt split checks"
  if ow_has nslookup; then
    nslookup "$RF_TARGET_R" 2>&1 || true
    nslookup "$FOREIGN_TARGET_R" 2>&1 || true
    ow_result "OK" "3 Split->RF" "DNS lookup attempted for $RF_TARGET_R"
    ow_result "OK" "4 Split->VPS/Foreign" "DNS lookup attempted for $FOREIGN_TARGET_R"
  else
    ow_missing "nslookup" "RF/foreign DNS checks"
  fi
  ow_ping "3 Split->RF" "RF target" "$RF_TARGET_R"
  ow_traceroute "3 Split->RF" "RF target" "$RF_TARGET_R"
  ow_http "3 Split->RF" "RF target HTTPS" "https://$RF_TARGET_R"
  ow_ping "4 Split->VPS/Foreign" "foreign target" "$FOREIGN_TARGET_R"
  ow_traceroute "4 Split->VPS/Foreign" "foreign target" "$FOREIGN_TARGET_R"
  ow_http "4 Split->VPS/Foreign" "foreign target HTTPS" "https://$FOREIGN_TARGET_R"
  ow_http "4 Split->VPS/Foreign" "router public IP" "https://ifconfig.me"
  if [ -n "$VPS_HOST_R" ]; then
    ow_ping "4 Split->VPS/Foreign" "VPS host" "$VPS_HOST_R"
    ow_traceroute "4 Split->VPS/Foreign" "VPS host" "$VPS_HOST_R"
    ow_tcp "4 Split->VPS/Foreign" "VPS SSH" "$VPS_HOST_R" "22"
  fi

  ow_section "OpenWrt speed tests"
  if [ "$SPEED_ENABLED_R" != "1" ]; then
    ow_result "SKIP" "7 Speed tests" "OpenWrt speed tests disabled by --no-speed"
  else
    ow_speed_http "OpenWrt RF timed download" "$SPEED_URL_RF_R"
    ow_speed_http "OpenWrt foreign timed download" "$SPEED_URL_FOREIGN_R"
    ow_iperf "OpenWrt -> iperf host" "$IPERF_HOST_R" "$IPERF_PORT_R"
  fi

  ow_section "OpenWrt MTU/MSS checks"
  ow_mtu_probe "RF target" "$RF_TARGET_R"
  ow_mtu_probe "foreign target" "$FOREIGN_TARGET_R"
  [ -n "$vhost" ] && ow_mtu_probe "VLESS host" "$vhost"
}

# Remote mode detection: when sent through ssh as "sh -s -- <rf> <foreign> ...",
# the first argument is not an option and no local output dir has been prepared.
case "${1:-}" in
  --*|-h|"")
    ;;
  *)
    openwrt_remote_main "$@"
    exit 0
    ;;
esac

write_header
show_run_banner
clear_proxy_environment
mac_tool_checks
if [ "$AUTO_TOGGLE_WG" = "1" ]; then
  run_auto_toggle_flow
else
  run_full_chain
fi
finalize
