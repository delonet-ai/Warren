#!/bin/sh
# Warren end-to-end test orchestrator.
# Runs entirely from Mac: flashes firmware, uploads Warren from local checkout,
# pre-configures, drives auto mode + VPS + Remote Admin, then verifies.
#
# Usage:
#   sh tools/test-e2e.sh --fw 25 --vps-host 1.2.3.4 --vps-pass secret
#   sh tools/test-e2e.sh --fw 24 --vps-host 1.2.3.4 --vps-pass secret --vps-port 2222
#   sh tools/test-e2e.sh --skip-flash --skip-chain-diag  # quick re-run
#
# Required:
#   --fw 24|25            OpenWrt family to flash (selects firmware from tools/os/)
#   --vps-host HOST       VPS IP for Warren auto mode
#   --vps-pass PASS       VPS root password
#
# Optional:
#   --router IP           Router IP after flash, default 192.168.1.1
#   --router-port PORT    Router SSH port, default 22
#   --router-bind IP      Local source address for router SSH (auto: address in router /24);
#                         needed on macOS when Wi-Fi and USB NIC share a subnet or route
#   --vps-port PORT       VPS SSH port, default 22
#   --skip-flash          Skip firmware flash, assume router already up
#   --resume              Skip flash and preserve existing warren.conf/state
#   --reinstall-3xui      Back up and reinstall an existing 3x-ui on the test VPS
#   --skip-chain-diag     Skip wg-vless-chain-diagnostics.sh at the end
#   --chain-loss-count N  Packets per long loss/jitter probe, default 240
#   --out DIR             Directory for test run logs
#   --wg-server HOST      WireGuard server for chain diag (default: VPS host)
#   --lan-target IP       LAN target for chain diag (default: router IP)
#   --local-ssh-port PORT Local port for Remote Admin SSH probe, default 2299
#   --local-luci-port PORT Local port for Remote Admin LuCI probe, default 8099
#   --remote-wait SEC     Remote Admin tunnel timeout, default 60

set -eu
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OS_DIR="$SCRIPT_DIR/os"

# ── load defaults from .env; explicit CLI flags override them ───────────────
env_file="$PROJECT_DIR/.env"
if [ -r "$env_file" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
fi

# ── defaults ────────────────────────────────────────────────────────────────
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
ROUTER_PORT="${ROUTER_PORT:-22}"
ROUTER_USER="${ROUTER_USER:-root}"
ROUTER_BIND="${ROUTER_BIND:-}"
VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-22}"
VPS_PASS="${VPS_PASS:-}"
FW_FAMILY="${FW_FAMILY:-}"
SKIP_FLASH="${SKIP_FLASH:-0}"
SKIP_CHAIN_DIAG="${SKIP_CHAIN_DIAG:-0}"
WG_SERVER="${WG_SERVER:-}"
LAN_TARGET="${LAN_TARGET:-}"
OUT_DIR="${OUT_DIR:-}"
REMOTE_LOCAL_SSH_PORT="${REMOTE_LOCAL_SSH_PORT:-2299}"
REMOTE_LOCAL_LUCI_PORT="${REMOTE_LOCAL_LUCI_PORT:-8099}"
REMOTE_WAIT_SECONDS="${REMOTE_WAIT_SECONDS:-60}"
REMOTE_REQUEST_TTL="${REMOTE_REQUEST_TTL:-300}"
E2E_REINSTALL_3XUI="${E2E_REINSTALL_3XUI:-0}"
RESUME_WARREN="${RESUME_WARREN:-0}"
CHAIN_LOSS_COUNT="${CHAIN_LOSS_COUNT:-240}"

# ── parse args ───────────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fw)           FW_FAMILY="${2:-}";    shift 2 ;;
    --router)       ROUTER_IP="${2:-}";    shift 2 ;;
    --router-port)  ROUTER_PORT="${2:-22}"; shift 2 ;;
    --router-bind)  ROUTER_BIND="${2:-}"; shift 2 ;;
    --vps-host)     VPS_HOST="${2:-}";     shift 2 ;;
    --vps-port)     VPS_PORT="${2:-22}";   shift 2 ;;
    --vps-pass)     VPS_PASS="${2:-}";     shift 2 ;;
    --skip-flash)   SKIP_FLASH=1;          shift 1 ;;
    --resume)       RESUME_WARREN=1; SKIP_FLASH=1; shift 1 ;;
    --reinstall-3xui) E2E_REINSTALL_3XUI=1; shift 1 ;;
    --skip-chain-diag) SKIP_CHAIN_DIAG=1; shift 1 ;;
    --chain-loss-count) CHAIN_LOSS_COUNT="${2:-}"; shift 2 ;;
    --out)          OUT_DIR="${2:-}";      shift 2 ;;
    --wg-server)    WG_SERVER="${2:-}";    shift 2 ;;
    --lan-target)   LAN_TARGET="${2:-}";   shift 2 ;;
    --local-ssh-port) REMOTE_LOCAL_SSH_PORT="${2:-}"; shift 2 ;;
    --local-luci-port) REMOTE_LOCAL_LUCI_PORT="${2:-}"; shift 2 ;;
    --remote-wait)  REMOTE_WAIT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
  esac
done

# ── router source address: on macOS a scoped USB NIC route loses to Wi-Fi ──
if [ -z "$ROUTER_BIND" ] && command -v ifconfig >/dev/null 2>&1; then
  router_net="${ROUTER_IP%.*}."
  ROUTER_BIND="$(ifconfig 2>/dev/null | awk -v net="$router_net" \
    '$1 == "inet" && index($2, net) == 1 { print $2; exit }')"
fi

# ── output dir ───────────────────────────────────────────────────────────────
TS="$(date +'%Y%m%d-%H%M%S')"
[ -n "$OUT_DIR" ] || OUT_DIR="$SCRIPT_DIR/test-runs/run-${FW_FAMILY:-?}-${TS}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR" 2>/dev/null || true
LOG="$OUT_DIR/run.log"
RESULTS="$OUT_DIR/results.tsv"
: > "$LOG"
: > "$RESULTS"
chmod 600 "$LOG" "$RESULTS" 2>/dev/null || true

# ── colours ──────────────────────────────────────────────────────────────────
G="\033[1;32m"; R="\033[1;31m"; Y="\033[1;33m"; NC="\033[0m"

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf "%b\n" "$*" | tee -a "$LOG"; }
step() { say ""; say "${Y}▶ $*${NC}"; }
ok()   { say "${G}  PASS${NC}  $*"; printf "PASS\t%s\n" "$*" >> "$RESULTS"; }
fail() { say "${R}  FAIL${NC}  $*"; printf "FAIL\t%s\n" "$*" >> "$RESULTS"; OVERALL_FAIL=1; }
skip() { say "  SKIP  $*"; printf "SKIP\t%s\n" "$*" >> "$RESULTS"; }
die()  { say "${R}FATAL${NC}  $*"; exit 1; }

redact_stream() {
  sed -E \
    -e "s#(vless|ss|trojan|socks4|socks5|hy2|hysteria2)://[^[:space:]']+#\\1://***#g" \
    -e "s#(VPS_ROOT_PASSWORD|PANEL_PASSWORD|PANEL_API_TOKEN|TG_BOT_TOKEN)=('[^']*'|[^[:space:]]*)#\\1='***'#g" \
    -e 's#^(Password:)[[:space:]].*$#\1 ***#' \
    -e 's#^(API token ensured:).*$#\1 ***#'
}

OVERALL_FAIL=0
REMOTE_CTRL="$SCRIPT_DIR/remote-admin/warren-remote-control.sh"
REMOTE_HOME="$OUT_DIR/remote-admin"
REMOTE_PROFILE_NAME=""
REMOTE_ROUTER_ID=""
REMOTE_FORWARD_PID=""
REMOTE_REQUEST_ACTIVE=0

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

remote_control() {
  WARREN_REMOTE_ADMIN_HOME="$REMOTE_HOME" sh "$REMOTE_CTRL" "$@"
}

router_ssh() {
  ssh -p "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
      -o LogLevel=ERROR \
      -o ConnectTimeout=8 \
      -o BatchMode=yes \
      "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

vps_ssh() {
  sshpass -p "$VPS_PASS" ssh -p "$VPS_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=8 \
      root@"$VPS_HOST" "$@"
}

cleanup_remote_admin() {
  if [ -n "${REMOTE_FORWARD_PID:-}" ] && kill -0 "$REMOTE_FORWARD_PID" 2>/dev/null; then
    kill "$REMOTE_FORWARD_PID" 2>/dev/null || true
    wait "$REMOTE_FORWARD_PID" 2>/dev/null || true
  fi
  REMOTE_FORWARD_PID=""

  if [ "${REMOTE_REQUEST_ACTIVE:-0}" = "1" ] &&
     [ -n "${REMOTE_PROFILE_NAME:-}" ] &&
     [ -n "${REMOTE_ROUTER_ID:-}" ]; then
    remote_control close \
      --vps "$REMOTE_PROFILE_NAME" \
      --router "$REMOTE_ROUTER_ID" >/dev/null 2>&1 || true
    router_ssh "/usr/bin/warren-remote-agent poll >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
  REMOTE_REQUEST_ACTIVE=0
}

trap cleanup_remote_admin EXIT
trap 'cleanup_remote_admin; exit 130' HUP INT TERM

router_scp() {
  # -O: legacy SCP protocol (OpenWrt lacks sftp-server)
  scp -O -P "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
      -o LogLevel=ERROR \
      -r "$1" "${ROUTER_USER}@${ROUTER_IP}:$2"
}

router_ssh_interactive() {
  ssh -p "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
      -o LogLevel=ERROR \
      -t \
      "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

wait_for_ssh() {
  max_wait="${1:-180}"
  say "  Ожидаю SSH на ${ROUTER_IP}:${ROUTER_PORT} (до ${max_wait}s)..."
  elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    if ssh -p "$ROUTER_PORT" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
           -o LogLevel=ERROR \
           -o ConnectTimeout=4 \
           -o BatchMode=yes \
           "${ROUTER_USER}@${ROUTER_IP}" true 2>/dev/null; then
      say "  SSH доступен (elapsed ${elapsed}s)"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "." >&2
  done
  printf "\n" >&2
  return 1
}

wait_for_ssh_down() {
  max_wait="${1:-90}"
  elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    if ! router_ssh true >/dev/null 2>&1; then
      say "  SSH отключился (elapsed ${elapsed}s)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

confirm() {
  # Auto-continue when stdin is not a terminal (CI / Bash tool / pipe)
  [ -t 0 ] || { say "  (non-interactive: auto-continue)"; return 0; }
  printf "\n${Y}▷ %s [Enter чтобы продолжить / Ctrl-C чтобы прервать]${NC} " "$1" >&2
  read -r _confirm_dummy || true
}

# ── prompt for missing required vars ─────────────────────────────────────────
prompt_secret() {
  label="$1"
  printf "%s: " "$label" >&2
  stty -echo 2>/dev/null || true
  read -r _ps_val
  stty echo 2>/dev/null || true
  printf "\n" >&2
  printf "%s" "$_ps_val"
}

prompt_plain() {
  label="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$label" "$default" >&2
  else
    printf "%s: " "$label" >&2
  fi
  read -r _pp_val
  [ -n "$_pp_val" ] || _pp_val="$default"
  printf "%s" "$_pp_val"
}

if [ -z "${VPS_HOST:-}" ]; then
  VPS_HOST="$(prompt_plain "VPS host/IP" "")"
fi
if [ -z "${VPS_PASS:-}" ]; then
  VPS_PASS="$(prompt_secret "VPS root password")"
fi
if [ -z "${VPS_PORT:-}" ]; then
  VPS_PORT="$(prompt_plain "VPS SSH port" "22")"
fi

# ── validate inputs ───────────────────────────────────────────────────────────
[ "$SKIP_FLASH" = "1" ] || [ -n "$FW_FAMILY" ] || die "--fw 24|25 обязателен (или --skip-flash)"
if [ "$SKIP_FLASH" != "1" ]; then
  case "$FW_FAMILY" in
    24|25) ;;
    *) die "--fw должен быть 24 или 25, получено: $FW_FAMILY" ;;
  esac
fi

# VPS required unless chain-diag-only run
if [ -z "$VPS_HOST" ] || [ -z "$VPS_PASS" ]; then
  die "--vps-host и --vps-pass обязательны"
fi

command -v sshpass >/dev/null 2>&1 || die "Для VPS password auth нужен sshpass"
command -v curl >/dev/null 2>&1 || die "Для E2E HTTP probes нужен curl"
command -v ssh-keyscan >/dev/null 2>&1 || die "Для E2E SSH probe нужен ssh-keyscan"

for port_value in "$ROUTER_PORT" "$VPS_PORT" "$REMOTE_LOCAL_SSH_PORT" "$REMOTE_LOCAL_LUCI_PORT"; do
  case "$port_value" in
    ""|*[!0-9]*) die "Порты должны быть целыми числами: $port_value" ;;
  esac
done
case "$REMOTE_WAIT_SECONDS" in
  ""|*[!0-9]*) die "--remote-wait должен быть целым числом" ;;
esac
case "$REMOTE_REQUEST_TTL" in
  ""|*[!0-9]*) die "REMOTE_REQUEST_TTL должен быть целым числом" ;;
esac
case "$CHAIN_LOSS_COUNT" in
  ""|*[!0-9]*) die "--chain-loss-count должен быть целым числом" ;;
esac

[ -n "$WG_SERVER" ] || WG_SERVER="$VPS_HOST"
[ -n "$LAN_TARGET" ] || LAN_TARGET="$ROUTER_IP"

say ""
say "═══════════════════════════════════════════════════════"
say "  Warren E2E Test  •  $(date +'%F %T')"
say "  Router:  ${ROUTER_USER}@${ROUTER_IP}:${ROUTER_PORT}"
say "  VPS:     ${VPS_HOST}:${VPS_PORT}"
say "  FW:      ${FW_FAMILY:-skip-flash}"
say "  Warren:  $([ "$RESUME_WARREN" = "1" ] && printf resume || printf fresh)"
say "  3x-ui:   $([ "$E2E_REINSTALL_3XUI" = "1" ] && printf reinstall || printf reuse)"
say "  Out:     $OUT_DIR"
say "═══════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PHASE 1: Flash firmware
# ════════════════════════════════════════════════════════════════════════════
phase_flash() {
  step "P1: Flash OpenWrt ${FW_FAMILY}.x firmware"

  fw_file="$(find "$OS_DIR" -maxdepth 1 -name "openwrt-${FW_FAMILY}.*" \
             \( -name "*.img" -o -name "*.img.gz" -o -name "*.bin" \) 2>/dev/null | sort | tail -n1)"
  [ -n "$fw_file" ] || die "Не найден firmware для семейства ${FW_FAMILY}.x в $OS_DIR"
  say "  Firmware: $fw_file ($(du -h "$fw_file" | cut -f1))"

  say "  Загружаю firmware на роутер..."
  fw_basename="$(basename "$fw_file")"
  router_scp "$fw_file" "/tmp/$fw_basename" >> "$LOG" 2>&1 \
    || die "Не удалось скопировать firmware на роутер"
  ok "P1: Firmware загружен: /tmp/$fw_basename"

  say "  Проверяю образ штатным sysupgrade -T..."
  if validation_output="$(router_ssh "sysupgrade -T /tmp/$fw_basename" 2>&1)"; then
    printf "%s\n" "$validation_output" >> "$LOG"
    ok "P1: sysupgrade принял образ"
  else
    printf "%s\n" "$validation_output" | tee -a "$LOG"
    die "sysupgrade отклонил образ; принудительная прошивка намеренно не выполняется"
  fi

  PRE_FLASH_BOOT_ID="$(router_ssh "cat /proc/sys/kernel/random/boot_id")"
  [ -n "$PRE_FLASH_BOOT_ID" ] || die "Не удалось прочитать boot_id перед прошивкой"

  say "  Запускаю sysupgrade -n (конфиг не сохраняется)..."
  say "  ${Y}Роутер уйдёт в перезагрузку, SSH-соединение оборвётся — это нормально.${NC}"
  router_ssh "sh -c 'sleep 2; sysupgrade -n /tmp/$fw_basename >/tmp/warren-sysupgrade.log 2>&1 </dev/null &'"
  if wait_for_ssh_down 90; then
    ok "P1: sysupgrade запущен, роутер ушёл в reboot"
  else
    router_ssh "cat /tmp/warren-sysupgrade.log 2>/dev/null || true" 2>/dev/null | tee -a "$LOG" || true
    die "Роутер не ушёл в reboot после sysupgrade"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2: Wait for router, verify OpenWrt version
# ════════════════════════════════════════════════════════════════════════════
phase_wait_boot() {
  step "P2: Ожидание загрузки роутера"

  wait_for_ssh 240 || die "Роутер не ответил по SSH за 240s после прошивки"
  ok "P2: SSH доступен"

  if [ "$SKIP_FLASH" != "1" ]; then
    post_flash_boot_id="$(router_ssh "cat /proc/sys/kernel/random/boot_id")"
    [ -n "$post_flash_boot_id" ] || die "Не удалось прочитать boot_id после прошивки"
    [ "$post_flash_boot_id" != "$PRE_FLASH_BOOT_ID" ] \
      || die "boot_id не изменился: фактическая перезагрузка не подтверждена"
    ok "P2: boot_id изменился — подтверждена новая загрузка"
  fi

  rel="$(router_ssh ". /etc/openwrt_release 2>/dev/null && printf '%s' \"\$DISTRIB_RELEASE\"")"
  say "  OpenWrt release: $rel"

  if [ -n "$FW_FAMILY" ]; then
    case "$rel" in
      "${FW_FAMILY}."*) ok "P2: OpenWrt $rel соответствует ожидаемому семейству ${FW_FAMILY}.x" ;;
      *) fail "P2: OpenWrt $rel НЕ соответствует ожидаемому семейству ${FW_FAMILY}.x" ;;
    esac
  else
    ok "P2: OpenWrt $rel (flash пропущен, версия не проверяется)"
  fi

  pm="$(router_ssh "if command -v apk >/dev/null 2>&1; then printf apk; elif command -v opkg >/dev/null 2>&1; then printf opkg; else printf unknown; fi")"
  say "  Package manager: $pm"
  ok "P2: Package manager: $pm"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 3: Upload Warren from local checkout
# ════════════════════════════════════════════════════════════════════════════
phase_upload_warren() {
  step "P3: Загрузка Warren из локального checkout"

  say "  Создаю /tmp/warren-dev/ на роутере..."
  router_ssh "rm -rf /tmp/warren-dev && mkdir -p /tmp/warren-dev/lib /tmp/warren-dev/assets" >> "$LOG" 2>&1

  say "  Копирую warren.sh..."
  router_scp "$PROJECT_DIR/warren.sh" "/tmp/warren-dev/warren.sh" >> "$LOG" 2>&1

  say "  Копирую lib/..."
  router_scp "$PROJECT_DIR/lib" "/tmp/warren-dev/" >> "$LOG" 2>&1

  say "  Копирую VERSION..."
  router_scp "$PROJECT_DIR/VERSION" "/tmp/warren-dev/VERSION" >> "$LOG" 2>&1
  router_scp "$PROJECT_DIR/SUMS.txt" "/tmp/warren-dev/SUMS.txt" >> "$LOG" 2>&1

  say "  Копирую assets/ и LuCI payload..."
  router_scp "$PROJECT_DIR/assets" "/tmp/warren-dev/" >> "$LOG" 2>&1
  router_scp "$PROJECT_DIR/luci-app-warren" "/tmp/warren-dev/" >> "$LOG" 2>&1

  uploaded="$(router_ssh "ls /tmp/warren-dev/lib/ | wc -l | tr -d ' '")"
  say "  Загружено lib файлов: $uploaded"
  [ "$uploaded" -gt 5 ] || fail "P3: Мало lib файлов ($uploaded), что-то не загрузилось"

  warren_ver="$(router_ssh "sed -n '1p' /tmp/warren-dev/VERSION 2>/dev/null || echo unknown")"
  say "  Warren VERSION: $warren_ver"
  ok "P3: Warren загружен (VERSION=$warren_ver, libs=$uploaded)"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 4: Pre-configure warren.conf for auto mode
# ════════════════════════════════════════════════════════════════════════════
phase_preconfigure() {
  step "P4: Pre-configure warren.conf для auto режима"

  say "  Создаю /etc/warren/ на роутере..."
  router_ssh "mkdir -p /etc/warren" >> "$LOG" 2>&1

  # Write the conf via heredoc over SSH
  # MODE=auto + AUTO_VPS_SOURCE=new_vps + VPS credentials → skips all interactive prompts
  # WARREN_DONE_SLEEP=0 + WARREN_WARN_SLEEP=0 → убирает паузы
  router_ssh "cat > /etc/warren/warren.conf" <<EOF
MODE='auto'
VLESS=''
LIST_RU=''
LIST_CF=''
LIST_META=''
LIST_GOOGLE_AI=''
AWG_ENDPOINT=''
VPS_HOST='${VPS_HOST}'
VPS_SSH_PORT='${VPS_PORT}'
VPS_ROOT_PASSWORD='${VPS_PASS}'
SELECTED_VPS_REPORT=''
AUTO_VPS_SOURCE='new_vps'
REMOTE_ADMIN_ROUTER_ID=''
REMOTE_ADMIN_ROUTER_NAME=''
REMOTE_ADMIN_ENDPOINTS=''
REMOTE_ADMIN_VPS_USER=''
REMOTE_ADMIN_POLL_INTERVAL=''
REMOTE_ADMIN_REQUEST_TTL=''
REMOTE_ADMIN_MAC_LUCI_PORT=''
REMOTE_ADMIN_LOCAL_SSH_PORT=''
REMOTE_ADMIN_LOCAL_LUCI_PORT=''
REMOTE_ADMIN_ROUTER_KEY_PATH=''
REMOTE_ADMIN_ENABLED=''
EOF

  router_ssh "chmod 600 /etc/warren/warren.conf" >> "$LOG" 2>&1

  # state=1: non-zero so should_resume_current_mode() bypasses the menu,
  # but below all thresholds so run_basic_flow starts from scratch.
  router_ssh "printf '1\n' > /etc/warren/warren.state" >> "$LOG" 2>&1

  conf_mode="$(router_ssh "grep '^MODE=' /etc/warren/warren.conf | cut -d= -f2-")"
  conf_vps="$(router_ssh "grep '^VPS_HOST=' /etc/warren/warren.conf | cut -d= -f2-")"
  state="$(router_ssh "cat /etc/warren/warren.state")"
  say "  conf MODE=$conf_mode, VPS_HOST=$conf_vps, state=$state"
  ok "P4: warren.conf записан (MODE=auto, AUTO_VPS_SOURCE=new_vps, state=1)"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 5: Run Warren auto mode on router (interactive SSH session)
# ════════════════════════════════════════════════════════════════════════════
# Helper: re-upload Warren files to /tmp/warren-dev/ (needed after expand-root reboot clears /tmp)
_reupload_warren() {
  say "  Повторная загрузка Warren на роутер (/tmp/ очистился при ребуте)..."
  _ru_attempt=0
  while [ "$_ru_attempt" -lt 3 ]; do
    if router_ssh "rm -rf /tmp/warren-dev && mkdir -p /tmp/warren-dev/lib /tmp/warren-dev/assets" >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/warren.sh" "/tmp/warren-dev/warren.sh" >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/lib"       "/tmp/warren-dev/"          >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/assets"    "/tmp/warren-dev/"          >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/luci-app-warren" "/tmp/warren-dev/"    >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/VERSION"   "/tmp/warren-dev/VERSION"   >> "$LOG" 2>&1 \
       && router_scp "$PROJECT_DIR/SUMS.txt"  "/tmp/warren-dev/SUMS.txt"  >> "$LOG" 2>&1; then
      break
    fi
    _ru_attempt=$((_ru_attempt + 1))
    [ "$_ru_attempt" -lt 3 ] || die "Не удалось загрузить Warren на роутер после 3 попыток"
    say "  (попытка $_ru_attempt/3 не удалась, retry через 10s...)"
    sleep 10
  done
  _rcu="$(router_ssh "ls /tmp/warren-dev/lib/ | wc -l | tr -d ' '")"
  say "  Загружено lib файлов: $_rcu"
}

# Helper: run one Warren pass and wait for completion.
#   Interactive: allocate PTY, user watches real-time (SSH stays open).
#   Non-interactive: launch Warren in background on router, poll state every 30s,
#   stream remote log to local file. Max wait: 60 minutes.
_run_warren_pass() {
  _warren_log="$1"
  _existing_3xui_action=1
  [ "$E2E_REINSTALL_3XUI" = "1" ] && _existing_3xui_action=2
  if [ -t 0 ]; then
    router_ssh_interactive \
      "WARREN_DONE_SLEEP=0 WARREN_WARN_SLEEP=0 WARREN_USE_LOCAL_LIBS=1 WARREN_SKIP_UPDATE_CHECK=1 WARREN_EXISTING_3XUI_ACTION=$_existing_3xui_action sh /tmp/warren-dev/warren.sh" \
      2>&1 | redact_stream | tee -a "$_warren_log" || true
    return 0
  fi

  # Non-interactive: write launcher, start in background, poll until done.
  router_ssh "cat > /tmp/warren-launcher.sh" <<LAUNCHER
#!/bin/sh
export WARREN_DONE_SLEEP=0 WARREN_WARN_SLEEP=0
export WARREN_USE_LOCAL_LIBS=1 WARREN_SKIP_UPDATE_CHECK=1
export WARREN_EXISTING_3XUI_ACTION=$_existing_3xui_action
exec sh /tmp/warren-dev/warren.sh
LAUNCHER
  router_ssh "chmod +x /tmp/warren-launcher.sh" >> "$LOG" 2>&1

  # Launch Warren detached; capture PID.
  # OpenWrt busybox has no nohup — use sh -c with & instead.
  # dropbear keeps background jobs alive after SSH session closes.
  _wpid="$(router_ssh \
    "sh -c 'sh /tmp/warren-launcher.sh </dev/null >/tmp/warren-run.log 2>&1 & printf \"%s\n\" \$!'" \
    2>/dev/null || echo 0)"
  say "  Warren запущен на роутере (PID=$_wpid), опрашиваю state каждые 30s..."

  _w_timeout=3600   # 60 minutes max
  _w_elapsed=0
  _w_done=0
  while [ "$_w_elapsed" -lt "$_w_timeout" ]; do
    sleep 30
    _w_elapsed=$((_w_elapsed + 30))

    # expand-root reboots the router while the pass is running. Do not turn
    # that expected SSH gap into state=0/process-dead.
    if ! router_ssh true >/dev/null 2>&1; then
      say "  [${_w_elapsed}s] SSH недоступен — ожидаю завершения reboot..."
      wait_for_ssh 240 || die "Роутер не вернулся после reboot во время Warren pass"
    fi

    # Download current log from router
    router_ssh "cat /tmp/warren-run.log 2>/dev/null || true" \
      2>/dev/null | redact_stream > "$_warren_log" || true

    _w_state="$(router_ssh \
      "cat /etc/warren/warren.state 2>/dev/null || printf '0'" 2>/dev/null || echo 0)"
    _w_alive="$(router_ssh \
      "kill -0 '$_wpid' 2>/dev/null && printf yes || printf no" 2>/dev/null || echo no)"

    say "  [${_w_elapsed}s] state=$_w_state pid=$_wpid alive=$_w_alive"

    if [ "$_w_state" = "100" ]; then
      say "  Warren завершился (state=100)"
      _w_done=1
      break
    fi
    if [ "$_w_alive" = "no" ]; then
      say "  Warren процесс завершился (state=$_w_state, не 100)"
      break
    fi
  done

  # Final log sync
  router_ssh "cat /tmp/warren-run.log 2>/dev/null || true" \
    2>/dev/null | redact_stream > "$_warren_log" || true
  [ "$_w_done" -eq 1 ] || say "  WARN: Warren не достиг state=100 (текущий state=$_w_state)"
}

phase_run_warren() {
  step "P5: Запуск Warren auto mode на роутере"

  say ""
  say "  Warren запустится в auto режиме с pre-set VPS данными."
  say "  Ожидаемый путь:"
  say "    • Базовая настройка OpenWrt (opkg/apk, expand root, timezone)"
  say "    • Установка Podkop + AmneziaWG + QoS"
  say "    • Подключение к VPS ($VPS_HOST), установка 3x-ui"
  say "    • Настройка VLESS + Reality inbound"
  say "    • Сохранение VLESS-ссылки в конфиг"
  say ""
  say "  Expand-root вызовет автоматический ребут роутера на mid-flow."
  say "  Скрипт дождётся его и перезапустит Warren со state=60."
  say ""
  say "  ${Y}Если Warren упал — прочитай ошибку и перезапусти с --skip-flash.${NC}"
  say ""
  confirm "Нажми Enter чтобы запустить Warren"

  warren_log="$OUT_DIR/warren-run.log"
  : > "$warren_log"   # truncate/create

  # ── Pass 1 ──────────────────────────────────────────────────────────────────
  say "  Запускаю Warren (pass 1)..."
  _run_warren_pass "$warren_log"

  # Check state after pass 1
  _p5_state="$(router_ssh "cat /etc/warren/warren.state 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
  say "  warren.state после pass 1: $_p5_state"

  # ── Reboot handling ─────────────────────────────────────────────────────────
  # expand_root_run_and_reboot() sets state=60 then calls reboot.
  # /tmp/ is cleared on reboot, so we must re-upload Warren before pass 2.
  if [ "$_p5_state" = "60" ]; then
    say "  Роутер перезагружается для expand-root (state=60). Жду 20s до опроса SSH..."
    sleep 20
    wait_for_ssh 240 || die "Роутер не ответил по SSH за 240s после expand-root ребута"
    _reupload_warren
    say "  Запускаю Warren (pass 2, state=60→100)..."
    _run_warren_pass "$warren_log"
    _p5_state="$(router_ssh "cat /etc/warren/warren.state 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
    say "  warren.state после pass 2: $_p5_state"
  fi

  say ""
  say "  Последние строки warren-run.log:"
  tail -30 "$warren_log" | sed 's/^/    /' | tee -a "$LOG" || true
  say ""
  confirm "Warren завершился (state=$_p5_state). Нажми Enter чтобы продолжить верификацию"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 6A: Install and verify exact AmneziaWG packages without changing routes
# ════════════════════════════════════════════════════════════════════════════
phase_install_awg_packages() {
  step "P6: AmneziaWG exact packages и runtime self-test"

  if ! router_ssh "command -v awg >/dev/null 2>&1 \
    && test -f /lib/netifd/proto/amneziawg.sh \
    && apk list --installed 2>/dev/null | grep -q '^kmod-amneziawg-' \
    && apk list --installed 2>/dev/null | grep -q '^amneziawg-tools-' \
    && apk list --installed 2>/dev/null | grep -q '^luci-proto-amneziawg-'"; then
    say "  Устанавливаю exact AWG packages через Warren resolver..."
    if ! router_ssh \
      "WARREN_DONE_SLEEP=0 WARREN_WARN_SLEEP=0 WARREN_LUCI_REQUEST=1 MODE=amnezia_client_create LOG=/tmp/warren-awg-install.log sh -s" \
      >> "$LOG" 2>&1 <<'AWG_INSTALL'
set -e
. /tmp/warren-dev/lib/common.sh
. /tmp/warren-dev/lib/versions.sh
. /tmp/warren-dev/lib/amneziawg.sh
warren_versions_apply_defaults
install_amneziawg
AWG_INSTALL
    then
      fail "P6: Не удалось установить exact AmneziaWG packages"
      return 0
    fi
  fi

  if router_ssh '
    modprobe amneziawg
    test -f /lib/netifd/proto/amneziawg.sh
    private="$(awg genkey)"
    public="$(printf "%s" "$private" | awg pubkey)"
    test -n "$private" && test -n "$public"
  '; then
    ok "P6: AWG module, tools keygen и netifd protocol работают"
  else
    fail "P6: AWG runtime self-test не прошёл"
  fi

  awg_packages="$(router_ssh "apk list --installed 2>/dev/null | grep -E '^(kmod-amneziawg|amneziawg-tools|luci-proto-amneziawg)-' | cut -d' ' -f1" 2>/dev/null || true)"
  say "  Installed AWG packages:"
  printf "%s\n" "$awg_packages" | sed '/^$/d; s/^/    /' | tee -a "$LOG"
  case "$awg_packages" in
    *kmod-amneziawg-*amneziawg-tools-*luci-proto-amneziawg-*|\
    *kmod-amneziawg-*luci-proto-amneziawg-*amneziawg-tools-*|\
    *amneziawg-tools-*kmod-amneziawg-*luci-proto-amneziawg-*|\
    *amneziawg-tools-*luci-proto-amneziawg-*kmod-amneziawg-*|\
    *luci-proto-amneziawg-*kmod-amneziawg-*amneziawg-tools-*|\
    *luci-proto-amneziawg-*amneziawg-tools-*kmod-amneziawg-*)
      ok "P6: полный комплект AWG packages установлен"
      ;;
    *)
      fail "P6: список AWG packages неполный"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 6: Verify Warren outcome
# ════════════════════════════════════════════════════════════════════════════
phase_verify_warren() {
  step "P6: Верификация результатов Warren"

  # State
  state="$(router_ssh "cat /etc/warren/warren.state 2>/dev/null || echo missing")"
  say "  warren.state: $state"
  if [ "$state" = "100" ]; then
    ok "P6: warren.state=100 (complete)"
  else
    fail "P6: warren.state=$state (ожидался 100)"
  fi

  # VLESS in conf
  vless="$(router_ssh "grep '^VLESS=' /etc/warren/warren.conf 2>/dev/null | cut -d= -f2- | tr -d \"'\"" 2>/dev/null || true)"
  if printf "%s" "$vless" | grep -Eq '^vless://'; then
    # Redact UUID portion for log
    vless_short="$(printf "%s" "$vless" | sed 's|vless://[^@]*@|vless://<UUID>@|')"
    say "  VLESS: $vless_short"
    ok "P6: VLESS-ссылка сохранена в конфиг"
  else
    fail "P6: VLESS-ссылка не найдена в конфиг (VPS setup не завершён?)"
  fi

  # VPS report file
  report="$(router_ssh "ls /etc/warren/vps/reports/*.txt 2>/dev/null | tail -n1 || echo missing")"
  say "  VPS report: $report"
  if [ "$report" != "missing" ] && [ -n "$report" ]; then
    ok "P6: VPS report создан: $report"
    # Copy report to Mac for reference
    scp -O -P "$ROUTER_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
        "${ROUTER_USER}@${ROUTER_IP}:$report" "$OUT_DIR/vps-report.txt" >> "$LOG" 2>&1 || true
  else
    fail "P6: VPS report не найден (configure_vless_reality не завершился?)"
  fi

  # OpenWrt pkg manager matches family
  rel="$(router_ssh ". /etc/openwrt_release 2>/dev/null && printf '%s' \"\$DISTRIB_RELEASE\"")"
  pm="$(router_ssh "command -v apk >/dev/null 2>&1 && printf apk || printf opkg")"
  family="$(printf "%s" "$rel" | cut -d. -f1)"
  case "$family-$pm" in
    24-opkg|25-apk) ok "P6: pkg manager $pm соответствует OpenWrt $rel" ;;
    *) fail "P6: pkg manager $pm НЕ соответствует OpenWrt $rel (ожидался $([ "$family" = "24" ] && echo opkg || echo apk))" ;;
  esac

  # Podkop runtime: use the same evidence model as Warren diagnostics/LuCI.
  podkop_snapshot="$(router_ssh ". /tmp/warren-dev/lib/podkop.sh; podkop_runtime_snapshot" 2>/dev/null || true)"
  podkop_health="$(printf "%s\n" "$podkop_snapshot" | tr ' ' '\n' | sed -n 's/^health=//p' | sed -n '1p')"
  say "  Podkop runtime: ${podkop_snapshot:-health=unknown}"
  if [ "$podkop_health" = "ok" ] || [ "$podkop_health" = "warn" ]; then
    ok "P6: Podkop runtime активен ($podkop_health)"
  else
    fail "P6: Podkop runtime не подтверждён (${podkop_snapshot:-нет данных})"
  fi

  # Connectivity from router
  say "  Проверяю связность с роутера..."
  if router_ssh "ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1"; then
    ok "P6: Роутер: ping 8.8.8.8 OK"
  else
    fail "P6: Роутер: ping 8.8.8.8 не проходит"
  fi

  if router_ssh "wget -qO /dev/null --timeout=10 https://ya.ru 2>/dev/null"; then
    ok "P6: Роутер: HTTPS ya.ru (RU трафик) OK"
  else
    fail "P6: Роутер: HTTPS ya.ru недоступен"
  fi

  if router_ssh "wget -qO /dev/null --timeout=10 https://google.com 2>/dev/null"; then
    ok "P6: Роутер: HTTPS google.com (foreign трафик через VLESS) OK"
  else
    fail "P6: Роутер: HTTPS google.com недоступен (VLESS/Podkop не работает?)"
  fi
}

prepare_remote_profile() {
  [ -r "$REMOTE_CTRL" ] || die "Не найден: $REMOTE_CTRL"
  REMOTE_PROFILE_NAME="e2e-${TS}"
  REMOTE_ROUTER_ID="$(printf "%s" "$ROUTER_IP" | tr -cs 'A-Za-z0-9._-' '-')"
  vps_profile_dir="$REMOTE_HOME/vps.d"
  vps_profile_file="$vps_profile_dir/${REMOTE_PROFILE_NAME}.conf"
  mkdir -p "$vps_profile_dir"
  {
    printf "VPS_NAME=%s\n" "$(quote_sh "$REMOTE_PROFILE_NAME")"
    printf "VPS_HOST=%s\n" "$(quote_sh "$VPS_HOST")"
    printf "VPS_SSH_PORT=%s\n" "$(quote_sh "$VPS_PORT")"
    printf "VPS_SSH_USER='root'\n"
    printf "VPS_SSH_KEY_PATH=''\n"
    printf "VPS_ROOT_PASSWORD=%s\n" "$(quote_sh "$VPS_PASS")"
    printf "REMOTE_HELPER_PATH='/usr/local/bin/warren-remote'\n"
    printf "DEFAULT_ROUTER_ID=%s\n" "$(quote_sh "$REMOTE_ROUTER_ID")"
    printf "LOCAL_SSH_PORT=%s\n" "$(quote_sh "$REMOTE_LOCAL_SSH_PORT")"
    printf "LOCAL_LUCI_PORT=%s\n" "$(quote_sh "$REMOTE_LOCAL_LUCI_PORT")"
    printf "REQUEST_TTL=%s\n" "$(quote_sh "$REMOTE_REQUEST_TTL")"
    printf "WAIT_SECONDS=%s\n" "$(quote_sh "$REMOTE_WAIT_SECONDS")"
  } > "$vps_profile_file"
  chmod 600 "$vps_profile_file"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 7: VPS — full readiness and Remote Admin helper
# ════════════════════════════════════════════════════════════════════════════
phase_vps_readiness() {
  step "P7: VPS — 3x-ui, VLESS Reality и Remote Admin helper"
  prepare_remote_profile

  if vps_ssh "printf '__WARREN_VPS_SSH_OK__\\n'" >/dev/null 2>&1; then
    ok "P7: VPS доступен по root SSH"
  else
    fail "P7: VPS недоступен по root SSH"
    return 0
  fi

  if vps_ssh "test -x /usr/local/x-ui/x-ui || command -v x-ui >/dev/null 2>&1"; then
    ok "P7: 3x-ui установлен"
  else
    fail "P7: 3x-ui не установлен"
  fi

  if vps_ssh "if command -v systemctl >/dev/null 2>&1; then systemctl is-active --quiet x-ui; else pgrep -f '[x]-ui' >/dev/null 2>&1; fi"; then
    ok "P7: 3x-ui service активен"
  else
    fail "P7: 3x-ui service не активен"
  fi

  if vps_ssh "pgrep -f '[x]ray' >/dev/null 2>&1"; then
    ok "P7: Xray Reality runtime запущен"
  else
    fail "P7: Xray runtime не найден"
  fi

  vless_authority="${vless#*@}"
  vless_authority="${vless_authority%%\?*}"
  vless_port="${vless_authority##*:}"
  case "$vless_port" in
    ""|*[!0-9]*)
      fail "P7: Не удалось определить VLESS port из результата Warren"
      ;;
    *)
      if vps_ssh "ss -lntH 2>/dev/null | grep -Eq '[:.]${vless_port}[[:space:]]' || netstat -lnt 2>/dev/null | grep -Eq '[:.]${vless_port}[[:space:]]'"; then
        ok "P7: VLESS inbound слушает TCP/$vless_port"
      else
        fail "P7: VLESS inbound не слушает TCP/$vless_port"
      fi
      ;;
  esac

  panel_url=""
  [ -r "$OUT_DIR/vps-report.txt" ] &&
    panel_url="$(sed -n 's/^3x-ui URL:[[:space:]]*//p' "$OUT_DIR/vps-report.txt" | head -n1)"
  case "$panel_url" in
    http://*|https://*)
      panel_scheme="${panel_url%%://*}"
      panel_rest="${panel_url#*://}"
      panel_authority="${panel_rest%%/*}"
      panel_port="${panel_authority##*:}"
      if [ "$panel_rest" = "$panel_authority" ]; then
        panel_path="/"
      else
        panel_path="/${panel_rest#*/}"
      fi
      case "$panel_port" in
        ""|*[!0-9]*)
          fail "P7: В VPS report некорректный URL панели"
          ;;
        *)
          panel_probe_url="${panel_scheme}://127.0.0.1:${panel_port}${panel_path}"
          panel_code="$(vps_ssh "curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 $(quote_sh "$panel_probe_url")" 2>/dev/null || true)"
          case "$panel_code" in
            2??|3??|401|403) ok "P7: 3x-ui panel отвечает локально (HTTP $panel_code)" ;;
            *) fail "P7: 3x-ui panel не прошёл локальную HTTP-проверку (HTTP ${panel_code:-000})" ;;
          esac
          ;;
      esac
      ;;
    *)
      fail "P7: URL панели не найден в VPS report"
      ;;
  esac

  helper_log="$OUT_DIR/vps-helper-install.log"
  say "  Устанавливаю/обновляю VPS helper для Remote Admin..."
  if remote_control vps install-helper --vps "$REMOTE_PROFILE_NAME" > "$helper_log" 2>&1; then
    redact_stream < "$helper_log" >> "$LOG"
    ok "P7: VPS helper установлен и инициализирован"
  else
    redact_stream < "$helper_log" >> "$LOG"
    fail "P7: Не удалось установить VPS helper (см. $helper_log)"
    return 0
  fi

  helper_check="$(remote_control vps check --vps "$REMOTE_PROFILE_NAME" 2>&1 || true)"
  printf "%s\n" "$helper_check" | redact_stream >> "$LOG"
  if printf "%s\n" "$helper_check" | grep -q '__WARREN_REMOTE_HELPER_LIST_OK__'; then
    ok "P7: VPS helper выполняет list"
  else
    fail "P7: VPS helper не прошёл check/list"
  fi

  if vps_ssh "test -d /var/lib/warren-remote && { test ! -d /etc/cron.d || test -r /etc/cron.d/warren-remote; }"; then
    ok "P7: VPS Remote Admin state и cleanup schedule готовы"
  else
    fail "P7: VPS Remote Admin state/cron не готовы"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 8: Remote Admin — request → tunnel → local SSH/LuCI → close
# ════════════════════════════════════════════════════════════════════════════
phase_remote_admin() {
  step "P8: Remote Admin — полный автоматический lifecycle"

  say "  Устанавливаю Remote Admin agent на роутер через SSH/SCP..."
  agent_install_log="$OUT_DIR/remote-agent-install.log"
  if remote_control router install-agent \
      --vps "$REMOTE_PROFILE_NAME" \
      --host "$ROUTER_IP" \
      --port "$ROUTER_PORT" \
      --user "$ROUTER_USER" > "$agent_install_log" 2>&1; then
    redact_stream < "$agent_install_log" >> "$LOG"
    ok "P8: warren-remote-agent установлен на роутере"
  else
    redact_stream < "$agent_install_log" >> "$LOG"
    fail "P8: Установка warren-remote-agent не удалась"
    return 0
  fi

  agent_status="$(router_ssh "/usr/bin/warren-remote-agent status 2>/dev/null" || true)"
  if printf "%s\n" "$agent_status" | grep -q '^DAEMON_STATUS=up$'; then
    ok "P8: warren-remote-agent daemon запущен"
  else
    fail "P8: warren-remote-agent daemon не запущен"
    return 0
  fi

  if router_ssh "/usr/bin/warren-remote-agent poll >/dev/null 2>&1"; then
    ok "P8: router agent зарегистрирован на VPS"
  else
    fail "P8: Первый poll agent → VPS завершился ошибкой"
    return 0
  fi

  if remote_control routers --vps "$REMOTE_PROFILE_NAME" 2>/dev/null | grep -q "^${REMOTE_ROUTER_ID}|"; then
    ok "P8: VPS видит router ID $REMOTE_ROUTER_ID"
  else
    fail "P8: VPS не видит router ID $REMOTE_ROUTER_ID"
    return 0
  fi

  request_result="$(remote_control request \
    --vps "$REMOTE_PROFILE_NAME" \
    --router "$REMOTE_ROUTER_ID" \
    --ttl "$REMOTE_REQUEST_TTL" 2>&1 || true)"
  if printf "%s\n" "$request_result" | grep -q '^ACTION=OPEN$'; then
    REMOTE_REQUEST_ACTIVE=1
    ok "P8: VPS создал запрос на открытие tunnel"
  else
    fail "P8: VPS не создал tunnel request"
    return 0
  fi

  if ! router_ssh "/usr/bin/warren-remote-agent poll >/dev/null 2>&1"; then
    fail "P8: Agent не обработал tunnel request"
    return 0
  fi

  remote_status=""
  remote_elapsed=0
  while [ "$remote_elapsed" -lt "$REMOTE_WAIT_SECONDS" ]; do
    remote_status="$(remote_control status \
      --vps "$REMOTE_PROFILE_NAME" \
      --router "$REMOTE_ROUTER_ID" 2>/dev/null || true)"
    if printf "%s\n" "$remote_status" | grep -q '^TUNNEL_STATUS=up$'; then
      break
    fi
    sleep 2
    remote_elapsed=$((remote_elapsed + 2))
  done

  remote_ssh_port="$(printf "%s\n" "$remote_status" | sed -n 's/^TUNNEL_SSH_PORT=//p' | head -n1)"
  remote_luci_port="$(printf "%s\n" "$remote_status" | sed -n 's/^TUNNEL_LUCI_PORT=//p' | head -n1)"
  case "${remote_ssh_port}:${remote_luci_port}" in
    *[!0-9:]*|:|*:|:*)
      fail "P8: VPS не подтвердил tunnel ports за ${REMOTE_WAIT_SECONDS}s"
      return 0
      ;;
    *)
      ok "P8: Reverse tunnel поднят на VPS"
      ;;
  esac

  if vps_ssh "ssh-keyscan -T 5 -p $remote_ssh_port 127.0.0.1 >/dev/null 2>&1"; then
    ok "P8: VPS достигает SSH роутера через reverse tunnel"
  else
    fail "P8: SSH роутера недоступен на VPS tunnel port"
  fi

  remote_luci_code="$(vps_ssh "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$remote_luci_port/" 2>/dev/null || true)"
  case "$remote_luci_code" in
    2??|3??|401|403) ok "P8: VPS достигает LuCI через reverse tunnel (HTTP $remote_luci_code)" ;;
    *) fail "P8: LuCI недоступен на VPS tunnel port (HTTP ${remote_luci_code:-000})" ;;
  esac

  forward_log="$OUT_DIR/remote-forward.log"
  sshpass -p "$VPS_PASS" ssh -N \
    -L "${REMOTE_LOCAL_SSH_PORT}:127.0.0.1:${remote_ssh_port}" \
    -L "${REMOTE_LOCAL_LUCI_PORT}:127.0.0.1:${remote_luci_port}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p "$VPS_PORT" "root@${VPS_HOST}" > "$forward_log" 2>&1 &
  REMOTE_FORWARD_PID=$!

  sleep 2
  if kill -0 "$REMOTE_FORWARD_PID" 2>/dev/null; then
    ok "P8: Mac открыл localhost forwards к VPS"
  else
    fail "P8: Не удалось открыть localhost forwards (см. $forward_log)"
    REMOTE_FORWARD_PID=""
    return 0
  fi

  if ssh-keyscan -T 5 -p "$REMOTE_LOCAL_SSH_PORT" 127.0.0.1 >/dev/null 2>&1; then
    ok "P8: SSH роутера доступен через localhost:$REMOTE_LOCAL_SSH_PORT"
  else
    fail "P8: SSH роутера недоступен через localhost forward"
  fi

  local_luci_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${REMOTE_LOCAL_LUCI_PORT}/" 2>/dev/null || true)"
  case "$local_luci_code" in
    2??|3??|401|403) ok "P8: LuCI доступен через localhost:$REMOTE_LOCAL_LUCI_PORT (HTTP $local_luci_code)" ;;
    *) fail "P8: LuCI недоступен через localhost forward (HTTP ${local_luci_code:-000})" ;;
  esac

  if remote_control close \
      --vps "$REMOTE_PROFILE_NAME" \
      --router "$REMOTE_ROUTER_ID" >/dev/null 2>&1 &&
     router_ssh "/usr/bin/warren-remote-agent poll >/dev/null 2>&1"; then
    REMOTE_REQUEST_ACTIVE=0
  else
    fail "P8: Не удалось закрыть Remote Admin request/tunnel"
    return 0
  fi

  close_status="$(remote_control status \
    --vps "$REMOTE_PROFILE_NAME" \
    --router "$REMOTE_ROUTER_ID" 2>/dev/null || true)"
  router_close_status="$(router_ssh "/usr/bin/warren-remote-agent status 2>/dev/null" || true)"
  if printf "%s\n" "$close_status" | grep -q '^TUNNEL_STATUS=down$' &&
     printf "%s\n" "$router_close_status" | grep -q '^TUNNEL_STATUS=down$'; then
    ok "P8: close погасил request и tunnel на VPS и роутере"
  else
    fail "P8: После close tunnel остался активен"
  fi

  cleanup_remote_admin
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 9: Chain diagnostics (wg-vless-chain-diagnostics.sh)
# ════════════════════════════════════════════════════════════════════════════
phase_chain_diag() {
  step "P9: Chain diagnostics (wg-vless-chain-diagnostics.sh)"

  diag_script="$SCRIPT_DIR/wg-vless-chain-diagnostics.sh"
  [ -r "$diag_script" ] || { skip "P9: $diag_script не найден"; return 0; }

  diag_out="$OUT_DIR/chain-diag"
  mkdir -p "$diag_out"

  say "  Запускаю: wg-vless-chain-diagnostics.sh --router ${ROUTER_USER}@${ROUTER_IP} --no-speed ..."
  sh "$diag_script" \
    --router "${ROUTER_USER}@${ROUTER_IP}" \
    --ssh-port "$ROUTER_PORT" \
    --lan-target "$LAN_TARGET" \
    --wg-server "$WG_SERVER" \
    --loss-count "$CHAIN_LOSS_COUNT" \
    --no-speed \
    --out "$diag_out" \
    --json \
    2>&1 | tee -a "$LOG" || true

  # Parse results from chain diag
  chain_bad=0
  chain_ok=0
  chain_warn=0
  if [ -f "$diag_out/results.tsv" ]; then
    chain_ok="$(awk -F'\t' '$1=="OK"{c++}END{print c+0}' "$diag_out/results.tsv")"
    chain_warn="$(awk -F'\t' '$1=="WARN"{c++}END{print c+0}' "$diag_out/results.tsv")"
    chain_bad="$(awk -F'\t' '$1=="BAD"{c++}END{print c+0}' "$diag_out/results.tsv")"
  fi

  say "  Chain diag totals: OK=$chain_ok WARN=$chain_warn BAD=$chain_bad"

  if [ "$chain_bad" -eq 0 ]; then
    ok "P9: Chain diagnostics: BAD=0 (OK=$chain_ok WARN=$chain_warn)"
  else
    fail "P9: Chain diagnostics: BAD=$chain_bad — см. $diag_out/summary.txt"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 10: Final report
# ════════════════════════════════════════════════════════════════════════════
phase_report() {
  say ""
  say "═══════════════════════════════════════════════════════"
  say "  Warren E2E Test Report  •  $(date +'%F %T')"
  say "═══════════════════════════════════════════════════════"

  pass_count="$(awk -F'\t' '$1=="PASS"{c++}END{print c+0}' "$RESULTS")"
  fail_count="$(awk -F'\t' '$1=="FAIL"{c++}END{print c+0}' "$RESULTS")"
  skip_count="$(awk -F'\t' '$1=="SKIP"{c++}END{print c+0}' "$RESULTS")"

  # Print each result
  while IFS="	" read -r status desc; do
    case "$status" in
      PASS) say "  ${G}✓${NC} $desc" ;;
      FAIL) say "  ${R}✗${NC} $desc" ;;
      SKIP) say "    $desc" ;;
    esac
  done < "$RESULTS"

  say ""
  say "  Итого: ${G}PASS=$pass_count${NC}  ${R}FAIL=$fail_count${NC}  SKIP=$skip_count"
  say "  Logs: $OUT_DIR"
  say "═══════════════════════════════════════════════════════"

  if [ "$OVERALL_FAIL" -eq 0 ]; then
    say ""
    say "${G}  ALL PASS — можно мержить в ветку после ревью.${NC}"
    say ""
    exit 0
  else
    say ""
    say "${R}  FAILURES DETECTED — не мержить до исправления.${NC}"
    say ""
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_FLASH" = "0" ]; then
  phase_flash
fi
phase_wait_boot
phase_upload_warren
if [ "$RESUME_WARREN" = "0" ]; then
  phase_preconfigure
else
  resume_state="$(router_ssh "cat /etc/warren/warren.state 2>/dev/null || echo missing")"
  [ "$resume_state" != "missing" ] || die "--resume: не найден /etc/warren/warren.state"
  say "  Resume: сохраняю существующие warren.conf/state=$resume_state"
fi
phase_run_warren
phase_install_awg_packages
phase_verify_warren
phase_vps_readiness
phase_remote_admin
if [ "$SKIP_CHAIN_DIAG" = "0" ]; then
  phase_chain_diag
else
  skip "P9: Chain diagnostics (--skip-chain-diag)"
fi
phase_report
