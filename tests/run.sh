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
. "$PROJECT_DIR/lib/versions.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/podkop.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/watchdog.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/remote_admin.sh"

printf "1..51\n"

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

# Network retry and download-integrity behavior.
RETRY_BIN="$TEST_TMP/retry-bin"
RETRY_COUNT="$TEST_TMP/retry-count"
RETRY_DELAYS="$TEST_TMP/retry-delays"
RETRY_OUT="$TEST_TMP/retry-output"
mkdir -p "$RETRY_BIN"
cat > "$RETRY_BIN/wget" <<'EOF'
#!/bin/sh
out="$2"
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

# Podkop Watchdog generated service and bounded recovery state machine.
WARREN_WATCHDOG_BIN="$TEST_TMP/warren-watchdog"
WARREN_WATCHDOG_INIT="$TEST_TMP/warren-watchdog.init"
WARREN_WATCHDOG_CONF="$TEST_TMP/warren-watchdog.conf"
WARREN_WATCHDOG_STATE="$TEST_TMP/warren-watchdog.state"
watchdog_write_worker
watchdog_write_init
assert_success "generated Podkop Watchdog worker has valid POSIX syntax" sh -n "$WARREN_WATCHDOG_BIN"
assert_success "generated Podkop Watchdog init has valid POSIX syntax" sh -n "$WARREN_WATCHDOG_INIT"

WATCHDOG_TEST_BIN="$TEST_TMP/watchdog-bin"
WATCHDOG_HEALTHY="$TEST_TMP/watchdog-healthy"
WATCHDOG_RESTARTS="$TEST_TMP/watchdog-restarts"
mkdir -p "$WATCHDOG_TEST_BIN"
cat > "$WATCHDOG_TEST_BIN/pgrep" <<'EOF'
#!/bin/sh
[ -e "${WARREN_TEST_WATCHDOG_HEALTHY:?}" ]
EOF
cat > "$WATCHDOG_TEST_BIN/ip" <<'EOF'
#!/bin/sh
printf "%s\n" "100: from all fwmark 0x2023 lookup 2023"
EOF
cat > "$WATCHDOG_TEST_BIN/podkop-init" <<'EOF'
#!/bin/sh
printf "%s\n" "${1:-}" >> "${WARREN_TEST_WATCHDOG_RESTARTS:?}"
touch "${WARREN_TEST_WATCHDOG_HEALTHY:?}"
EOF
chmod +x "$WATCHDOG_TEST_BIN/pgrep" "$WATCHDOG_TEST_BIN/ip" "$WATCHDOG_TEST_BIN/podkop-init"
{
  printf "WARREN_WATCHDOG_INTERVAL=1\n"
  printf "WARREN_WATCHDOG_RESTART_DELAY=0\n"
  printf "WARREN_WATCHDOG_STABLE_WINDOW=1\n"
} > "$WARREN_WATCHDOG_CONF"

watchdog_recovers_engine() {
  rm -f "$WATCHDOG_HEALTHY" "$WATCHDOG_RESTARTS" "$WARREN_WATCHDOG_STATE"
  PATH="$WATCHDOG_TEST_BIN:$PATH" \
  WARREN_TEST_WATCHDOG_HEALTHY="$WATCHDOG_HEALTHY" \
  WARREN_TEST_WATCHDOG_RESTARTS="$WATCHDOG_RESTARTS" \
  WARREN_WATCHDOG_CONF="$WARREN_WATCHDOG_CONF" \
  WARREN_WATCHDOG_STATE="$WARREN_WATCHDOG_STATE" \
  WARREN_WATCHDOG_PODKOP_INIT="$WATCHDOG_TEST_BIN/podkop-init" \
    "$WARREN_WATCHDOG_BIN" run-once
  grep -q "^STATUS=restarted$" "$WARREN_WATCHDOG_STATE" &&
    grep -q "^restart$" "$WATCHDOG_RESTARTS"
}
assert_success "Podkop Watchdog restarts a missing engine once" watchdog_recovers_engine

watchdog_stops_after_three_failures() {
  rm -f "$WATCHDOG_HEALTHY" "$WATCHDOG_RESTARTS"
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
    "$WARREN_WATCHDOG_BIN" run-once >/dev/null 2>&1 || true
  grep -q "^STATUS=exhausted$" "$WARREN_WATCHDOG_STATE" &&
    [ ! -e "$WATCHDOG_RESTARTS" ]
}
assert_success "Podkop Watchdog stops after three rapid failures" watchdog_stops_after_three_failures

printf "\nPassed: %d  Failed: %d\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
