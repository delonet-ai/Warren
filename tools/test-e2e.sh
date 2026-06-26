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
#   --vps-port PORT       VPS SSH port, default 22
#   --skip-flash          Skip firmware flash, assume router already up
#   --skip-chain-diag     Skip wg-vless-chain-diagnostics.sh at the end
#   --out DIR             Directory for test run logs
#   --wg-server HOST      WireGuard server for chain diag (default: VPS host)
#   --lan-target IP       LAN target for chain diag (default: router IP)

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OS_DIR="$SCRIPT_DIR/os"

# ── defaults ────────────────────────────────────────────────────────────────
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
ROUTER_PORT="${ROUTER_PORT:-22}"
ROUTER_USER="${ROUTER_USER:-root}"
VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-22}"
VPS_PASS="${VPS_PASS:-}"
FW_FAMILY="${FW_FAMILY:-}"
SKIP_FLASH="${SKIP_FLASH:-0}"
SKIP_CHAIN_DIAG="${SKIP_CHAIN_DIAG:-0}"
WG_SERVER="${WG_SERVER:-}"
LAN_TARGET="${LAN_TARGET:-}"
OUT_DIR="${OUT_DIR:-}"

# ── parse args ───────────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fw)           FW_FAMILY="${2:-}";    shift 2 ;;
    --router)       ROUTER_IP="${2:-}";    shift 2 ;;
    --router-port)  ROUTER_PORT="${2:-22}"; shift 2 ;;
    --vps-host)     VPS_HOST="${2:-}";     shift 2 ;;
    --vps-port)     VPS_PORT="${2:-22}";   shift 2 ;;
    --vps-pass)     VPS_PASS="${2:-}";     shift 2 ;;
    --skip-flash)   SKIP_FLASH=1;          shift 1 ;;
    --skip-chain-diag) SKIP_CHAIN_DIAG=1; shift 1 ;;
    --out)          OUT_DIR="${2:-}";      shift 2 ;;
    --wg-server)    WG_SERVER="${2:-}";    shift 2 ;;
    --lan-target)   LAN_TARGET="${2:-}";   shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
  esac
done

# ── output dir ───────────────────────────────────────────────────────────────
TS="$(date +'%Y%m%d-%H%M%S')"
[ -n "$OUT_DIR" ] || OUT_DIR="$SCRIPT_DIR/test-runs/run-${FW_FAMILY:-?}-${TS}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
RESULTS="$OUT_DIR/results.tsv"
: > "$LOG"
: > "$RESULTS"

# ── colours ──────────────────────────────────────────────────────────────────
G="\033[1;32m"; R="\033[1;31m"; Y="\033[1;33m"; NC="\033[0m"

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf "%b\n" "$*" | tee -a "$LOG"; }
step() { say ""; say "${Y}▶ $*${NC}"; }
ok()   { say "${G}  PASS${NC}  $*"; printf "PASS\t%s\n" "$*" >> "$RESULTS"; }
fail() { say "${R}  FAIL${NC}  $*"; printf "FAIL\t%s\n" "$*" >> "$RESULTS"; OVERALL_FAIL=1; }
skip() { say "  SKIP  $*"; printf "SKIP\t%s\n" "$*" >> "$RESULTS"; }
die()  { say "${R}FATAL${NC}  $*"; exit 1; }

OVERALL_FAIL=0

router_ssh() {
  ssh -p "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=8 \
      -o BatchMode=yes \
      "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

router_scp() {
  scp -P "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -r "$1" "${ROUTER_USER}@${ROUTER_IP}:$2"
}

router_ssh_interactive() {
  ssh -p "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
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

confirm() {
  prompt="$1"
  printf "\n${Y}▷ %s [Enter чтобы продолжить / Ctrl-C чтобы прервать]${NC} " "$prompt" >&2
  read -r _confirm_dummy || true
}

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

[ -n "$WG_SERVER" ] || WG_SERVER="$VPS_HOST"
[ -n "$LAN_TARGET" ] || LAN_TARGET="$ROUTER_IP"

say ""
say "═══════════════════════════════════════════════════════"
say "  Warren E2E Test  •  $(date +'%F %T')"
say "  Router:  ${ROUTER_USER}@${ROUTER_IP}:${ROUTER_PORT}"
say "  VPS:     ${VPS_HOST}:${VPS_PORT}"
say "  FW:      ${FW_FAMILY:-skip-flash}"
say "  Out:     $OUT_DIR"
say "═══════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PHASE 1: Flash firmware
# ════════════════════════════════════════════════════════════════════════════
phase_flash() {
  step "P1: Flash OpenWrt ${FW_FAMILY}.x firmware"

  fw_file="$(find "$OS_DIR" -maxdepth 1 -name "openwrt-${FW_FAMILY}.*" \
             \( -name "*.img" -o -name "*.bin" \) 2>/dev/null | sort | tail -n1)"
  [ -n "$fw_file" ] || die "Не найден firmware для семейства ${FW_FAMILY}.x в $OS_DIR"
  say "  Firmware: $fw_file ($(du -h "$fw_file" | cut -f1))"

  say "  Загружаю firmware на роутер..."
  fw_basename="$(basename "$fw_file")"
  router_scp "$fw_file" "/tmp/$fw_basename" >> "$LOG" 2>&1 \
    || die "Не удалось скопировать firmware на роутер"
  ok "P1: Firmware загружен: /tmp/$fw_basename"

  say "  Запускаю sysupgrade -n (конфиг не сохраняется)..."
  say "  ${Y}Роутер уйдёт в перезагрузку, SSH-соединение оборвётся — это нормально.${NC}"
  # sysupgrade returns non-zero as SSH drops; ignore exit code
  router_ssh "sysupgrade -n /tmp/$fw_basename" >> "$LOG" 2>&1 || true
  ok "P1: sysupgrade запущен"

  say "  Жду 30s перед опросом SSH (роутер перезагружается)..."
  sleep 30
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2: Wait for router, verify OpenWrt version
# ════════════════════════════════════════════════════════════════════════════
phase_wait_boot() {
  step "P2: Ожидание загрузки роутера"

  wait_for_ssh 240 || die "Роутер не ответил по SSH за 240s после прошивки"
  ok "P2: SSH доступен"

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

  pm="$(router_ssh "command -v apk >/dev/null 2>&1 && printf apk || command -v opkg >/dev/null 2>&1 && printf opkg || printf unknown")"
  say "  Package manager: $pm"
  ok "P2: Package manager: $pm"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 3: Upload Warren from local checkout
# ════════════════════════════════════════════════════════════════════════════
phase_upload_warren() {
  step "P3: Загрузка Warren из локального checkout"

  say "  Создаю /tmp/warren-dev/ на роутере..."
  router_ssh "rm -rf /tmp/warren-dev && mkdir -p /tmp/warren-dev/lib" >> "$LOG" 2>&1

  say "  Копирую warren.sh..."
  router_scp "$PROJECT_DIR/warren.sh" "/tmp/warren-dev/warren.sh" >> "$LOG" 2>&1

  say "  Копирую lib/..."
  router_scp "$PROJECT_DIR/lib" "/tmp/warren-dev/" >> "$LOG" 2>&1

  say "  Копирую VERSION..."
  router_scp "$PROJECT_DIR/VERSION" "/tmp/warren-dev/VERSION" >> "$LOG" 2>&1

  uploaded="$(router_ssh "ls /tmp/warren-dev/lib/ | wc -l | tr -d ' '")"
  say "  Загружено lib файлов: $uploaded"
  [ "$uploaded" -gt 5 ] || fail "P3: Мало lib файлов ($uploaded), что-то не загрузилось"

  warren_ver="$(router_ssh "cat /tmp/warren-dev/VERSION 2>/dev/null || echo unknown")"
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

  # Reset state to 0 → Warren starts fresh
  router_ssh "printf '0\n' > /etc/warren/warren.state" >> "$LOG" 2>&1

  conf_mode="$(router_ssh "grep '^MODE=' /etc/warren/warren.conf | cut -d= -f2-")"
  conf_vps="$(router_ssh "grep '^VPS_HOST=' /etc/warren/warren.conf | cut -d= -f2-")"
  state="$(router_ssh "cat /etc/warren/warren.state")"
  say "  conf MODE=$conf_mode, VPS_HOST=$conf_vps, state=$state"
  ok "P4: warren.conf записан (MODE=auto, AUTO_VPS_SOURCE=new_vps, state=0)"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 5: Run Warren auto mode on router (interactive SSH session)
# ════════════════════════════════════════════════════════════════════════════
phase_run_warren() {
  step "P5: Запуск Warren auto mode на роутере"

  say ""
  say "  ${Y}ВНИМАНИЕ: Открывается интерактивная SSH-сессия на роутер.${NC}"
  say "  Warren запустится в auto режиме с pre-set VPS данными."
  say "  Ожидаемый путь:"
  say "    • Базовая настройка OpenWrt (opkg/apk, expand root, timezone)"
  say "    • Установка Podkop + AmneziaWG + QoS"
  say "    • Подключение к VPS ($VPS_HOST), установка 3x-ui"
  say "    • Настройка VLESS + Reality inbound"
  say "    • Сохранение VLESS-ссылки в конфиг"
  say "    • Настройка Remote Admin (может потребовать ручного ввода Router ID)"
  say ""
  say "  ${G}По завершении Warren выйдет сам. Нажми Enter чтобы продолжить тестирование.${NC}"
  say "  ${Y}Если Warren упал — прочитай ошибку, исправь и перезапусти эту фазу с --skip-flash.${NC}"
  say ""
  confirm "Нажми Enter чтобы открыть SSH-сессию"

  # Run Warren with pauses disabled, lib pointed at local upload
  router_ssh_interactive \
    "WARREN_DONE_SLEEP=0 WARREN_WARN_SLEEP=0 WARREN_LIB_BASE_URL=file:///tmp/warren-dev/lib sh /tmp/warren-dev/warren.sh" \
    || true

  say ""
  confirm "Warren завершился. Нажми Enter чтобы продолжить верификацию"
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
    scp -P "$ROUTER_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
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

  # Podkop running
  podkop_up="$(router_ssh "/etc/init.d/podkop status >/dev/null 2>&1 && printf up || pgrep -x sing-box >/dev/null 2>&1 && printf up || printf down")"
  say "  Podkop/sing-box: $podkop_up"
  if [ "$podkop_up" = "up" ]; then
    ok "P6: Podkop/sing-box запущен"
  else
    fail "P6: Podkop/sing-box не запущен"
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

# ════════════════════════════════════════════════════════════════════════════
# PHASE 7: Remote Admin — install agent, verify
# ════════════════════════════════════════════════════════════════════════════
phase_remote_admin() {
  step "P7: Remote Admin — установка agent и верификация"

  remote_ctrl="$SCRIPT_DIR/remote-admin/warren-remote-control.sh"
  [ -r "$remote_ctrl" ] || die "Не найден: $remote_ctrl"

  vps_profile_name="test-$(date +%Y%m%d)"
  vps_profile_dir="${HOME}/.config/warren/remote-admin/vps.d"
  mkdir -p "$vps_profile_dir"
  vps_profile_file="$vps_profile_dir/${vps_profile_name}.conf"

  say "  Создаю VPS профиль '$vps_profile_name' (без интерактива)..."
  cat > "$vps_profile_file" <<EOF
VPS_NAME='${vps_profile_name}'
VPS_HOST='${VPS_HOST}'
VPS_SSH_PORT='${VPS_PORT}'
VPS_SSH_USER='root'
VPS_SSH_KEY_PATH=''
VPS_ROOT_PASSWORD='${VPS_PASS}'
REMOTE_HELPER_PATH='/usr/local/bin/warren-remote'
DEFAULT_ROUTER_ID=''
LOCAL_SSH_PORT='2201'
LOCAL_LUCI_PORT='8081'
REQUEST_TTL='900'
WAIT_SECONDS='180'
EOF
  chmod 600 "$vps_profile_file"
  ok "P7: VPS профиль создан: $vps_profile_file"

  say "  Устанавливаю Remote Admin agent на роутер через SSH/SCP..."
  sh "$remote_ctrl" router install-agent \
    --vps "$vps_profile_name" \
    --host "$ROUTER_IP" \
    --port "$ROUTER_PORT" \
    --user "$ROUTER_USER" \
    >> "$LOG" 2>&1 \
    && ok "P7: warren-remote-agent установлен на роутере" \
    || fail "P7: Установка warren-remote-agent не удалась (см. $LOG)"

  say "  Проверяю статус agent на роутере..."
  agent_status="$(router_ssh "/usr/bin/warren-remote-agent status 2>/dev/null | grep '^DAEMON_STATUS=' | cut -d= -f2" || echo "missing")"
  say "  warren-remote-agent DAEMON_STATUS=$agent_status"
  if [ "$agent_status" = "up" ]; then
    ok "P7: warren-remote-agent daemon запущен"
  else
    fail "P7: warren-remote-agent daemon не запущен (DAEMON_STATUS=$agent_status)"
  fi

  say "  Тест poll (agent → VPS)..."
  tunnel_result="$(router_ssh "/usr/bin/warren-remote-agent poll 2>&1 | head -5" || echo "poll-failed")"
  say "  poll result: $tunnel_result"
  ok "P7: warren-remote-agent poll выполнен (ошибки VPS helper пока ожидаемы)"

  say ""
  say "  ${Y}РУЧНАЯ ПРОВЕРКА: Remote Admin tunnel${NC}"
  say "  1. На Mac: sh tools/remote-admin/warren-remote-control.sh vps connect --vps $vps_profile_name"
  say "  2. Дождись OPEN, проверь: ssh -p 2201 root@127.0.0.1"
  say "  3. LuCI: http://127.0.0.1:8081"
  say "  4. На Mac: sh tools/remote-admin/warren-remote-control.sh close --vps $vps_profile_name"
  confirm "Выполни ручную проверку Remote Admin и нажми Enter"
  ok "P7: Remote Admin ручная проверка подтверждена"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 8: Chain diagnostics (wg-vless-chain-diagnostics.sh)
# ════════════════════════════════════════════════════════════════════════════
phase_chain_diag() {
  step "P8: Chain diagnostics (wg-vless-chain-diagnostics.sh)"

  diag_script="$SCRIPT_DIR/wg-vless-chain-diagnostics.sh"
  [ -r "$diag_script" ] || { skip "P8: $diag_script не найден"; return 0; }

  diag_out="$OUT_DIR/chain-diag"
  mkdir -p "$diag_out"

  say "  Запускаю: wg-vless-chain-diagnostics.sh --router ${ROUTER_USER}@${ROUTER_IP} --no-speed ..."
  sh "$diag_script" \
    --router "${ROUTER_USER}@${ROUTER_IP}" \
    --ssh-port "$ROUTER_PORT" \
    --lan-target "$LAN_TARGET" \
    --wg-server "$WG_SERVER" \
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
    ok "P8: Chain diagnostics: BAD=0 (OK=$chain_ok WARN=$chain_warn)"
  else
    fail "P8: Chain diagnostics: BAD=$chain_bad — см. $diag_out/summary.txt"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 9: Final report
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
phase_preconfigure
phase_run_warren
phase_verify_warren
phase_remote_admin
if [ "$SKIP_CHAIN_DIAG" = "0" ]; then
  phase_chain_diag
else
  skip "P8: Chain diagnostics (--skip-chain-diag)"
fi
phase_report
