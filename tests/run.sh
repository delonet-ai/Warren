#!/bin/sh
# Fast POSIX-shell regression tests. No router, network or root access required.

set -u
WARREN_WARN_SLEEP=0

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP="${TMPDIR:-/tmp}/warren-tests.$$"
PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "$TEST_TMP"
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "ok %d - %s\n" "$PASS_COUNT" "$1"
}

fail_test() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "not ok - %s\n" "$1" >&2
  [ -z "${2:-}" ] || printf "  %s\n" "$2" >&2
}

assert_eq() {
  expected="$1"
  actual="$2"
  label="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail_test "$label" "expected=[$expected] actual=[$actual]"
  fi
}

assert_success() {
  label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail_test "$label" "command failed: $*"
  fi
}

assert_failure() {
  label="$1"
  shift
  if "$@"; then
    fail_test "$label" "command unexpectedly succeeded: $*"
  else
    pass "$label"
  fi
}

WARREN_PAYLOAD_DIR="$PROJECT_DIR/payload"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/ui.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/state.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/modes.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/versions.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/basic.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/podkop.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/watchdog.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/remote_admin.sh"

printf "1..70\n"

# Version policy and generated dependency URLs.
assert_eq "24" "$(warren_openwrt_family 24.05.0)" "OpenWrt 24.x maps to family 24"
assert_eq "25" "$(warren_openwrt_family 25.07.2)" "OpenWrt 25.x maps to family 25"
assert_eq "unknown/graceful" "$(warren_openwrt_family 26.01.0)" "OpenWrt 26.x enters graceful family"
assert_eq "unknown/graceful" "$(warren_openwrt_family 30.2.1)" "future OpenWrt major enters graceful family"
WARREN_ALLOW_UNKNOWN_OPENWRT=1
assert_success "CI flag accepts unknown OpenWrt without prompt" warren_check_pkg_manager_matches_openwrt 26.01.0 apk
unset WARREN_ALLOW_UNKNOWN_OPENWRT
assert_eq "opkg" "$(warren_expected_pkg_manager_for_release 24.10.6)" "24.x expects opkg"
assert_eq "apk" "$(warren_expected_pkg_manager_for_release 25.12.3)" "25.x expects apk"
assert_eq "1.0" "$(warren_awg_protocol_version_for_release 24.05.0)" "older 24.x selects AWG protocol 1.0"
assert_eq "2.0" "$(warren_awg_protocol_version_for_release 24.10.6)" "newer 24.x selects AWG protocol 2.0"
assert_eq \
  "https://raw.githubusercontent.com/itdoginfo/podkop/refs/tags/0.7.21/install.sh" \
  "$(warren_podkop_install_url_default)" \
  "Podkop pinned installer URL contains one canonical tag"
assert_eq "25.12.5" "$WARREN_OPENWRT_PINNED_RELEASE" "tested OpenWrt release is pinned"
PODKOP_INSTALL_SHA256=""
WARREN_3XUI_RELEASE_TAG=""
warren_versions_apply_defaults
assert_eq "$WARREN_PODKOP_INSTALL_SHA256" "$PODKOP_INSTALL_SHA256" "Podkop installer SHA256 is applied by default"
assert_eq "v3.5.0" "$WARREN_3XUI_RELEASE_TAG" "3x-ui release tag is applied by default"
assert_eq "f2f8caa11778d811a037fe84b20ebf5e2547fd665afe6fe16d69f1cd9f3fe88f" \
  "$WARREN_3XUI_INSTALL_SHA256" \
  "3x-ui installer SHA256 is pinned"

# Safe config round-trip: shell-looking text must stay data.
STATE="$TEST_TMP/warren.state"
CONF="$TEST_TMP/warren.conf"
LOG="$TEST_TMP/warren.log"
AUTO_STATE_STORE="$TEST_TMP/runtime.tsv"
AUTO_STATE_JSON="$TEST_TMP/runtime.json"
injection_marker="$TEST_TMP/config-was-executed"
MODE="auto"
VLESS="vless://client@example.invalid:443"
VPS_ROOT_PASSWORD="pa'ss;\$(touch $injection_marker)"
REMOTE_ADMIN_ROUTER_NAME="router one"
save_conf

MODE=""
VLESS=""
VPS_ROOT_PASSWORD=""
REMOTE_ADMIN_ROUTER_NAME=""
load_conf_if_exists

assert_eq "auto" "$MODE" "config parser restores whitelisted mode"
assert_eq "vless://client@example.invalid:443" "$VLESS" "config parser restores proxy URL"
assert_eq "pa'ss;\$(touch $injection_marker)" "$VPS_ROOT_PASSWORD" "config parser preserves shell-looking text literally"
assert_eq "router one" "$REMOTE_ADMIN_ROUTER_NAME" "config parser preserves spaces"
assert_failure "config values are never executed" test -e "$injection_marker"

# A hand-written command after a quoted value is rejected as malformed.
printf "MODE='auto'; touch '%s'\n" "$injection_marker" > "$CONF"
MODE="sentinel"
load_conf_if_exists
assert_eq "sentinel" "$MODE" "malformed executable config line is ignored"
assert_failure "malformed config line cannot execute a command" test -e "$injection_marker"

# Atomic state and legacy mode normalization.
rm -f "$STATE" "${STATE}.tmp"
assert_eq "0" "$(get_state)" "missing state starts at zero"
set_state 60
assert_eq "60" "$(get_state)" "state transition persists"
assert_failure "atomic state leaves no temporary file" test -e "${STATE}.tmp"
MODE="3"
normalize_mode
assert_eq "add_private" "$MODE" "legacy mode is normalized"

# VLESS URL generation.
runtime_state_set() { :; }
CLIENT_UUID="11111111-2222-3333-4444-555555555555"
VPS_HOST="203.0.113.10"
INBOUND_PORT="443"
REALITY_PUBLIC_KEY="public-key"
REALITY_FINGERPRINT="chrome"
REALITY_SERVER_NAME_1="example.com"
SID_PRIMARY="abcd1234"
CLIENT_FLOW="xtls-rprx-vision"
CLIENT_COMMENT="warren"
build_vless_link
assert_eq \
  "vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp&security=reality&pbk=public-key&fp=chrome&sni=example.com&sid=abcd1234&spx=%2F&flow=xtls-rprx-vision#warren" \
  "$VLESS_LINK" \
  "VLESS Reality URL is deterministic"

# Canonical Podkop runtime evidence model.
TEST_INIT=0
TEST_ENGINE=0
TEST_CONFIG=0
TEST_RULES=0
TEST_NFT=0
podkop_init_running() { [ "$TEST_INIT" = "1" ]; }
podkop_engine_running() { [ "$TEST_ENGINE" = "1" ]; }
podkop_config_ok() { [ "$TEST_CONFIG" = "1" ]; }
podkop_rules_active() { [ "$TEST_RULES" = "1" ]; }
podkop_nft_active() { [ "$TEST_NFT" = "1" ]; }

TEST_INIT=1
snapshot="$(podkop_runtime_snapshot)"
assert_eq "ok" "$(podkop_runtime_field "$snapshot" health)" "Podkop init status is healthy"

TEST_INIT=0
TEST_ENGINE=1
TEST_CONFIG=1
TEST_RULES=1
snapshot="$(podkop_runtime_snapshot)"
assert_eq "warn" "$(podkop_runtime_field "$snapshot" health)" "active Podkop evidence tolerates a broken init status"
assert_success "warning Podkop runtime still counts as active" podkop_runtime_healthy "$snapshot"

TEST_RULES=0
snapshot="$(podkop_runtime_snapshot)"
assert_eq "bad" "$(podkop_runtime_field "$snapshot" health)" "insufficient Podkop evidence is unhealthy"

# Remote Admin helper lifecycle: close must be delivered once to stop the
# router-side reverse tunnel, then disappear.
REMOTE_HELPER_TEST="$TEST_TMP/warren-remote"
REMOTE_HELPER_STATE="$TEST_TMP/remote-helper-state"
REMOTE_HELPER_CRON="$TEST_TMP/warren-remote.cron"
remote_admin_write_vps_helper "$REMOTE_HELPER_TEST"
assert_success "generated Remote Admin helper has valid POSIX syntax" sh -n "$REMOTE_HELPER_TEST"
assert_success "Remote Admin helper initializes isolated state" \
  env WARREN_REMOTE_ADMIN_BASE_DIR="$REMOTE_HELPER_STATE" \
      WARREN_REMOTE_ADMIN_CRON_FILE="$REMOTE_HELPER_CRON" \
      sh "$REMOTE_HELPER_TEST" init
remote_request="$(
  WARREN_REMOTE_ADMIN_BASE_DIR="$REMOTE_HELPER_STATE" \
  WARREN_REMOTE_ADMIN_CRON_FILE="$REMOTE_HELPER_CRON" \
    sh "$REMOTE_HELPER_TEST" request test-router 300
)"
assert_eq "OPEN" "$(printf "%s\n" "$remote_request" | sed -n 's/^ACTION=//p')" "Remote Admin request emits OPEN"
WARREN_REMOTE_ADMIN_BASE_DIR="$REMOTE_HELPER_STATE" \
WARREN_REMOTE_ADMIN_CRON_FILE="$REMOTE_HELPER_CRON" \
  sh "$REMOTE_HELPER_TEST" close test-router
remote_close_poll="$(
  WARREN_REMOTE_ADMIN_BASE_DIR="$REMOTE_HELPER_STATE" \
  WARREN_REMOTE_ADMIN_CRON_FILE="$REMOTE_HELPER_CRON" \
    sh "$REMOTE_HELPER_TEST" poll test-router
)"
assert_eq "CLOSE" "$(printf "%s\n" "$remote_close_poll" | sed -n 's/^ACTION=//p')" "Remote Admin close reaches router poll"
remote_idle_poll="$(
  WARREN_REMOTE_ADMIN_BASE_DIR="$REMOTE_HELPER_STATE" \
  WARREN_REMOTE_ADMIN_CRON_FILE="$REMOTE_HELPER_CRON" \
    sh "$REMOTE_HELPER_TEST" poll test-router
)"
assert_eq "NONE" "$(printf "%s\n" "$remote_idle_poll" | sed -n 's/^ACTION=//p')" "Remote Admin close is consumed exactly once"

# Shared Podkop health probes (payload/podkop-health.sh).
HEALTH_PROC="$TEST_TMP/health-proc"
podkop_engine_seen_in_proc() {
  rm -rf "$HEALTH_PROC"; mkdir -p "$HEALTH_PROC/77"
  printf "sing-box\n" > "$HEALTH_PROC/77/comm"
  (PODKOP_HEALTH_PROC="$HEALTH_PROC"; . "$PROJECT_DIR/payload/podkop-health.sh"; podkop_engine_running) &&
    printf "sing-box-helper\n" > "$HEALTH_PROC/77/comm" &&
    ! (PODKOP_HEALTH_PROC="$HEALTH_PROC"; . "$PROJECT_DIR/payload/podkop-health.sh"; podkop_engine_running)
}
assert_success "engine is detected by exact /proc comm name" podkop_engine_seen_in_proc

assert_success "LuCI can execute the health probe for a snapshot line" sh -c '
  PODKOP_HEALTH_PROC="$1" PODKOP_INIT_SCRIPT=/nonexistent sh "$2/payload/podkop-health.sh" snapshot |
    grep -Eq "^health=(ok|warn|bad) init=0 engine=0 config=[01] rules=[01] nft=[01] evidence=[0-9]+$"
' _ "$TEST_TMP/empty-proc" "$PROJECT_DIR"

assert_eq "sing-box-not-running" \
  "$(PODKOP_HEALTH_PROC="$TEST_TMP/empty-proc" sh "$PROJECT_DIR/payload/podkop-health.sh" reason)" \
  "watchdog reason reports a missing engine first"

# Mode registry: one table drives menu, dispatch and resume targets.
registry_handlers_exist() {
  missing=""
  for h in $(printf "%s\n" "$WARREN_MODES" | awk -F'|' 'NF >= 6 && $5 != "-" { print $5 }'); do
    grep -q "^${h}() {" "$PROJECT_DIR/warren.sh" "$PROJECT_DIR"/lib/*.sh || missing="$missing $h"
  done
  [ -z "$missing" ] || { printf "missing handlers:%s\n" "$missing" >&2; return 1; }
}
assert_success "every registry handler is a defined function" registry_handlers_exist

registry_menu_unique() {
  dup="$(printf "%s\n" "$WARREN_MODES" | awk -F'|' 'NF >= 6 && $2 != "-" { print $2 }' | sort | uniq -d)"
  [ -z "$dup" ]
}
assert_success "menu numbers are unique" registry_menu_unique

luci_modes_registered() {
  bad=""
  for m in $(sed -n 's/.*name="mode" value="\([a-z_]*\)".*/\1/p' "$PROJECT_DIR/luci-app-warren/luasrc/view/warren/index.htm" | sort -u); do
    warren_mode_known "$m" && [ "$(warren_mode_kind "$m")" != "submenu" ] || bad="$bad $m"
  done
  [ -z "$bad" ] || { printf "unknown LuCI modes:%s\n" "$bad" >&2; return 1; }
}
assert_success "every LuCI mode button maps to a registered mode" luci_modes_registered

assert_eq "0-16, 99" "$(warren_menu_range)" "menu prompt range is derived from the registry"
assert_eq "podkop_backup" "$(warren_mode_by_menu 4.2)" "submenu item resolves to its mode"
assert_eq "100 95 0" "$(MODE=auto mode_target_state) $(MODE=podkop_setup mode_target_state) $(MODE=vps mode_target_state)" \
  "flow modes keep their resume targets"
assert_success "service mode is one-shot" sh -c '. "$1/lib/modes.sh"; MODE=vps mode_is_one_shot_service' _ "$PROJECT_DIR"
assert_failure "flow mode is resumable" sh -c '. "$1/lib/modes.sh"; MODE=basic mode_is_one_shot_service' _ "$PROJECT_DIR"

registry_dispatches_service() {
  (
    watchdog_reset() { printf "ran" > "$TEST_TMP/dispatch"; }
    conf_set() { :; }
    cleanup_runtime_state() { :; }
    MODE=watchdog_reset
    run_service_mode
  )
  [ "$(cat "$TEST_TMP/dispatch" 2>/dev/null)" = "ran" ] &&
    ! (MODE=basic; run_service_mode)
}
assert_success "run_service_mode calls the registry handler and skips flow modes" registry_dispatches_service

menu_submenu_saves_service_mode() {
  (
    CONF="$TEST_TMP/menu.conf"; STATE="$TEST_TMP/menu.state"; LOG=/dev/null
    rm -f "$CONF"; printf "0\n" > "$STATE"
    clear_terminal() { :; }
    print_banner() { :; }
    say() { :; }
    ask() {
      case "$2" in
        MENU_CHOICE) MENU_CHOICE=4 ;;
        SUBMENU_CHOICE) SUBMENU_CHOICE=2 ;;
      esac
    }
    menu
    [ "$MODE" = "podkop_backup" ] && grep -q "^MODE='podkop_backup'$" "$CONF"
  )
}
assert_success "menu -> Podkop submenu -> backup mode is saved" menu_submenu_saves_service_mode

# Network retry and download-integrity behavior.
RETRY_BIN="$TEST_TMP/retry-bin"
RETRY_COUNT="$TEST_TMP/retry-count"
RETRY_DELAYS="$TEST_TMP/retry-delays"
RETRY_OUT="$TEST_TMP/retry-output"
mkdir -p "$RETRY_BIN"
cat > "$RETRY_BIN/wget" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  [ -n "${WARREN_TEST_WGET_GNU:-}" ] && printf "GNU Wget 1.24.5\n" && exit 0
  exit 1
fi
[ -z "${WARREN_TEST_WGET_ARGS:-}" ] || printf "%s\n" "$*" > "$WARREN_TEST_WGET_ARGS"
out=""
prev=""
for arg in "$@"; do
  case "$prev" in -qO|-O) out="$arg" ;; esac
  prev="$arg"
done
count_file="${WARREN_TEST_RETRY_COUNT:?}"
count="$(cat "$count_file" 2>/dev/null || printf 0)"
count=$((count + 1))
printf "%s\n" "$count" > "$count_file"
[ "$count" -ge "${WARREN_TEST_SUCCEED_ON:-1}" ] || exit 1
printf "%s" "${WARREN_TEST_PAYLOAD:-payload}" > "$out"
EOF
chmod +x "$RETRY_BIN/wget"

retry_recovers_after_temporary_failure() {
  (
    PATH="$RETRY_BIN:$PATH"
    WARREN_TEST_RETRY_COUNT="$RETRY_COUNT"
    WARREN_TEST_SUCCEED_ON=3
    WARREN_TEST_PAYLOAD="verified payload"
    export PATH WARREN_TEST_RETRY_COUNT WARREN_TEST_SUCCEED_ON WARREN_TEST_PAYLOAD
    sleep() { printf "%s\n" "$1" >> "$RETRY_DELAYS"; }
    rm -f "$RETRY_COUNT" "$RETRY_DELAYS" "$RETRY_OUT"
    expected_sha="$(printf "%s" "$WARREN_TEST_PAYLOAD" | sha256sum | awk '{print $1}')"
    warren_download_retry "https://example.invalid/payload" "$RETRY_OUT" "$expected_sha" "test payload" &&
      [ "$(cat "$RETRY_COUNT")" = "3" ] &&
      [ "$(tr '\n' ' ' < "$RETRY_DELAYS")" = "5 15 " ] &&
      [ "$(cat "$RETRY_OUT")" = "$WARREN_TEST_PAYLOAD" ]
  )
}
assert_success "temporary network failure retries with 5s/15s backoff" retry_recovers_after_temporary_failure

wget_timeout_flags() {
  (
    PATH="$RETRY_BIN:$PATH"
    WARREN_TEST_RETRY_COUNT="$RETRY_COUNT"
    WARREN_TEST_WGET_ARGS="$TEST_TMP/wget-args"
    export PATH WARREN_TEST_RETRY_COUNT WARREN_TEST_WGET_ARGS
    warren_wget -qO "$RETRY_OUT" https://example.invalid/a &&
      [ "$(cat "$WARREN_TEST_WGET_ARGS")" = "-T 20 -qO $RETRY_OUT https://example.invalid/a" ] &&
      WARREN_TEST_WGET_GNU=1 && export WARREN_TEST_WGET_GNU &&
      warren_wget -qO "$RETRY_OUT" https://example.invalid/b &&
      [ "$(cat "$WARREN_TEST_WGET_ARGS")" = "-T 20 --tries=1 -qO $RETRY_OUT https://example.invalid/b" ]
  )
}
assert_success "wget gets an inactivity timeout and GNU wget a single try" wget_timeout_flags

inet_waits_for_wan() {
  (
    PING_COUNT="$TEST_TMP/ping-count"
    rm -f "$PING_COUNT"
    ping() {
      n="$(cat "$PING_COUNT" 2>/dev/null || printf 0)"; n=$((n + 1))
      printf "%s\n" "$n" > "$PING_COUNT"
      [ "$n" -ge 5 ]
    }
    sleep() { :; }
    WARREN_DONE_SLEEP=0
    check_inet >/dev/null 2>&1 && [ "$(cat "$PING_COUNT")" = "5" ]
  )
}
assert_success "check_inet waits for WAN instead of failing on the first ping" inet_waits_for_wan

# AmneziaWG release resolver: transient probe failures retry, and a fallback
# release is used only when it ships the running kernel.
awg_stub_wget() {
  url=""; out=""; prev=""
  for arg in "$@"; do
    case "$prev" in -qO) out="$arg" ;; esac
    url="$arg"; prev="$arg"
  done
  case "$url" in
    */profiles.json)
      printf '{"linux_kernel":{"release":"1","version":"%s"}}' "${AWG_TEST_CANDIDATE_KERNEL:?}" > "$out" ;;
    */v25.12.5/*)
      n="$(cat "$AWG_TEST_COUNT" 2>/dev/null || printf 0)"; n=$((n + 1)); printf "%s" "$n" > "$AWG_TEST_COUNT"
      [ "$n" -gt "${AWG_TEST_EXACT_FAILS:-0}" ] ;;
    *) return 0 ;;
  esac
}

awg_select() {
  (
    AWG_TEST_COUNT="$TEST_TMP/awg-count"; rm -f "$AWG_TEST_COUNT"
    AWG_STAGE_DIR="$TEST_TMP/awg-stage"
    WARREN_RUNNING_KERNEL="6.12.94"
    warren_wget() { awg_stub_wget "$@"; }
    sleep() { :; }
    warren_awg_select_release 25.12.5 apk aarch64_generic rockchip armv8 | sed -n '1p'
  )
}

assert_eq "25.12.5|exact" "$(AWG_TEST_EXACT_FAILS=2 AWG_TEST_CANDIDATE_KERNEL=6.12.94 awg_select)" \
  "AWG exact release survives two transient probe failures"
assert_eq "" "$(AWG_TEST_EXACT_FAILS=999 AWG_TEST_CANDIDATE_KERNEL=6.12.74 awg_select)" \
  "AWG fallback built for another kernel is rejected"
assert_eq "25.12.4|fallback" "$(AWG_TEST_EXACT_FAILS=999 AWG_TEST_CANDIDATE_KERNEL=6.12.94 awg_select)" \
  "AWG fallback with the running kernel is accepted"

retry_rejects_tampered_payload() {
  (
    PATH="$RETRY_BIN:$PATH"
    WARREN_TEST_RETRY_COUNT="$RETRY_COUNT"
    WARREN_TEST_SUCCEED_ON=1
    WARREN_TEST_PAYLOAD="tampered"
    export PATH WARREN_TEST_RETRY_COUNT WARREN_TEST_SUCCEED_ON WARREN_TEST_PAYLOAD
    sleep() { :; }
    rm -f "$RETRY_COUNT" "$RETRY_OUT"
    warren_download_retry "https://example.invalid/payload" "$RETRY_OUT" \
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "tampered payload"
  )
}
assert_failure "tampered download is rejected after retries" retry_rejects_tampered_payload
assert_failure "rejected download is removed" test -e "$RETRY_OUT"

skip_hash_check_allows_dev_payload() {
  (
    PATH="$RETRY_BIN:$PATH"
    WARREN_TEST_RETRY_COUNT="$RETRY_COUNT"
    WARREN_TEST_SUCCEED_ON=1
    WARREN_TEST_PAYLOAD="dev payload"
    WARREN_SKIP_HASH_CHECK=1
    export PATH WARREN_TEST_RETRY_COUNT WARREN_TEST_SUCCEED_ON WARREN_TEST_PAYLOAD WARREN_SKIP_HASH_CHECK
    rm -f "$RETRY_COUNT" "$RETRY_OUT"
    warren_download_retry "https://example.invalid/payload" "$RETRY_OUT" "" "dev payload"
  )
}
assert_success "WARREN_SKIP_HASH_CHECK allows manifest-free dev download" skip_hash_check_allows_dev_payload

manifest_fixture="$TEST_TMP/SUMS.txt"
printf "%s  lib/common.sh\n" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$manifest_fixture"
assert_eq \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$(warren_manifest_sha "$manifest_fixture" "lib/common.sh")" \
  "manifest resolves an exact payload path"

# Security hardening: dynamic prompt assignment and logs never execute or leak.
warren_set_var SECURITY_TEST_VALUE "literal;\$(touch $injection_marker)"
assert_eq "literal;\$(touch $injection_marker)" "$SECURITY_TEST_VALUE" "ask variable helper preserves shell-looking text"
assert_failure "ask variable helper cannot execute assigned text" test -e "$injection_marker"

: > "$LOG"
log "VPS_ROOT_PASSWORD=top-secret-value"
assert_failure "sensitive log value is redacted" grep -q "top-secret-value" "$LOG"
assert_success "sensitive log entry keeps a redaction marker" grep -q "\\*\\*\\*" "$LOG"

forget_vps_password_after_success() {
  VPS_ROOT_PASSWORD="temporary-root-password"
  save_conf
  vps_forget_root_password
  [ -z "$VPS_ROOT_PASSWORD" ] &&
    grep -q "^VPS_ROOT_PASSWORD=''$" "$CONF"
}
assert_success "successful VPS setup removes root password from config" forget_vps_password_after_success

# Shipped payloads install atomically and a missing payload stops the flow.
warren_install_payload warren-qos.init "$TEST_TMP/payload-install/warren-qos.init"
assert_success "payload installs byte-identical from payload/" \
  cmp -s "$PROJECT_DIR/payload/warren-qos.init" "$TEST_TMP/payload-install/warren-qos.init"
assert_failure "missing payload fails instead of writing an empty service" \
  sh -c '. "$1/lib/common.sh"; WARREN_PAYLOAD_DIR="$1/payload"; WARREN_WARN_SLEEP=0; LOG=/dev/null; warren_install_payload no-such-payload "$2/x" >/dev/null 2>&1' _ "$PROJECT_DIR" "$TEST_TMP"

# Remote Admin agent parses its config instead of sourcing it.
remote_agent_config_is_data() {
  ra_dir="$TEST_TMP/ra-config"; rm -rf "$ra_dir"; mkdir -p "$ra_dir"
  {
    printf "REMOTE_ADMIN_ROUTER_ID=r1\n"
    printf "REMOTE_ADMIN_ROUTER_NAME=My Router; touch %s/pwned\n" "$ra_dir"
    printf "REMOTE_ADMIN_ENDPOINTS='203.0.113.10:22'\n"
    printf "REMOTE_ADMIN_ROUTER_KEY_PATH=%s/key\n" "$ra_dir"
    printf "REMOTE_ADMIN_LOCAL_SSH_PORT=22x\n"
    printf "EVIL=\$(touch %s/pwned2)\n" "$ra_dir"
  } > "$ra_dir/agent.conf"
  out="$(WARREN_REMOTE_ADMIN_CONFIG="$ra_dir/agent.conf" \
    WARREN_REMOTE_ADMIN_RUNTIME_DIR="$ra_dir/run" \
    WARREN_REMOTE_ADMIN_LOG_FILE="$ra_dir/log" \
    sh "$PROJECT_DIR/payload/warren-remote-agent" status)" &&
    printf "%s\n" "$out" | grep -qx "ROUTER_NAME=My Router; touch $ra_dir/pwned" &&
    printf "%s\n" "$out" | grep -qx "ENDPOINTS=203.0.113.10:22" &&
    printf "%s\n" "$out" | grep -qx "LOCAL_SSH_PORT=2201" &&
    [ ! -e "$ra_dir/pwned" ] && [ ! -e "$ra_dir/pwned2" ]
}
assert_success "Remote Admin agent config values are data, not shell" remote_agent_config_is_data

# Podkop Watchdog generated service and bounded recovery state machine.
WARREN_WATCHDOG_BIN="$TEST_TMP/warren-watchdog"
WARREN_WATCHDOG_INIT="$TEST_TMP/warren-watchdog.init"
WARREN_WATCHDOG_CONF="$TEST_TMP/warren-watchdog.conf"
WARREN_WATCHDOG_STATE="$TEST_TMP/warren-watchdog.state"
PODKOP_HEALTH_BIN="$TEST_TMP/podkop-health.sh"
watchdog_write_worker
watchdog_write_init
assert_success "generated Podkop Watchdog worker has valid POSIX syntax" sh -n "$WARREN_WATCHDOG_BIN"
assert_success "generated Podkop Watchdog init has valid POSIX syntax" sh -n "$WARREN_WATCHDOG_INIT"

WATCHDOG_TEST_BIN="$TEST_TMP/watchdog-bin"
WATCHDOG_HEALTHY="$TEST_TMP/watchdog-healthy"
WATCHDOG_RESTARTS="$TEST_TMP/watchdog-restarts"
mkdir -p "$WATCHDOG_TEST_BIN"
cat > "$WATCHDOG_TEST_BIN/ip" <<'EOF'
#!/bin/sh
printf "%s\n" "100: from all fwmark 0x2023 lookup 2023"
EOF
cat > "$WATCHDOG_TEST_BIN/podkop-init" <<'EOF'
#!/bin/sh
printf "%s\n" "${1:-}" >> "${WARREN_TEST_WATCHDOG_RESTARTS:?}"
mkdir -p "${PODKOP_HEALTH_PROC:?}/4242"
printf "sing-box\n" > "$PODKOP_HEALTH_PROC/4242/comm"
EOF
chmod +x "$WATCHDOG_TEST_BIN/ip" "$WATCHDOG_TEST_BIN/podkop-init"
WATCHDOG_PROC="$TEST_TMP/watchdog-proc"
{
  printf "WARREN_WATCHDOG_INTERVAL=1\n"
  printf "WARREN_WATCHDOG_RESTART_DELAY=0\n"
  printf "WARREN_WATCHDOG_STABLE_WINDOW=1\n"
} > "$WARREN_WATCHDOG_CONF"

watchdog_recovers_engine() {
  rm -rf "$WATCHDOG_HEALTHY" "$WATCHDOG_RESTARTS" "$WARREN_WATCHDOG_STATE" "$WATCHDOG_PROC"
  mkdir -p "$WATCHDOG_PROC"
  PATH="$WATCHDOG_TEST_BIN:$PATH" \
  WARREN_TEST_WATCHDOG_HEALTHY="$WATCHDOG_HEALTHY" \
  WARREN_TEST_WATCHDOG_RESTARTS="$WATCHDOG_RESTARTS" \
  WARREN_WATCHDOG_CONF="$WARREN_WATCHDOG_CONF" \
  WARREN_WATCHDOG_STATE="$WARREN_WATCHDOG_STATE" \
  WARREN_WATCHDOG_PODKOP_INIT="$WATCHDOG_TEST_BIN/podkop-init" \
  WARREN_WATCHDOG_HEALTH="$PODKOP_HEALTH_BIN" \
  PODKOP_HEALTH_PROC="$WATCHDOG_PROC" \
    "$WARREN_WATCHDOG_BIN" run-once
  grep -q "^STATUS=restarted$" "$WARREN_WATCHDOG_STATE" &&
    grep -q "^restart$" "$WATCHDOG_RESTARTS"
}
assert_success "Podkop Watchdog restarts a missing engine once" watchdog_recovers_engine

watchdog_stops_after_three_failures() {
  rm -rf "$WATCHDOG_HEALTHY" "$WATCHDOG_RESTARTS" "$WATCHDOG_PROC"
  mkdir -p "$WATCHDOG_PROC"
  {
    printf "STATUS=backoff\n"
    printf "LAST_CHECK=1\n"
    printf "LAST_RESTART=1\n"
    printf "RESTART_COUNT=3\n"
    printf "FAILURE_COUNT=3\n"
    printf "BACKOFF_UNTIL=0\n"
    printf "STABLE_SINCE=0\n"
    printf "LAST_REASON=sing-box-not-running\n"
  } > "$WARREN_WATCHDOG_STATE"
  PATH="$WATCHDOG_TEST_BIN:$PATH" \
  WARREN_TEST_WATCHDOG_HEALTHY="$WATCHDOG_HEALTHY" \
  WARREN_TEST_WATCHDOG_RESTARTS="$WATCHDOG_RESTARTS" \
  WARREN_WATCHDOG_CONF="$WARREN_WATCHDOG_CONF" \
  WARREN_WATCHDOG_STATE="$WARREN_WATCHDOG_STATE" \
  WARREN_WATCHDOG_PODKOP_INIT="$WATCHDOG_TEST_BIN/podkop-init" \
  WARREN_WATCHDOG_HEALTH="$PODKOP_HEALTH_BIN" \
  PODKOP_HEALTH_PROC="$WATCHDOG_PROC" \
    "$WARREN_WATCHDOG_BIN" run-once >/dev/null 2>&1 || true
  grep -q "^STATUS=exhausted$" "$WARREN_WATCHDOG_STATE" &&
    [ ! -e "$WATCHDOG_RESTARTS" ]
}
assert_success "Podkop Watchdog stops after three rapid failures" watchdog_stops_after_three_failures

printf "\nPassed: %d  Failed: %d\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
