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
. "$PROJECT_DIR/lib/vps_report.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps_ssh.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps_3xui.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps_reality.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/vps.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/watchdog.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/lib/remote_admin.sh"

printf "1..72\n"

# Generate the actual panel payload without SSH; empty minClientVer breaks sing-box.
reality_payload_accepts_sing_box() (
  vps_workspace_dir() { printf '%s\n' "$TEST_TMP"; }
  vps_write_remote_file() { return 0; }
  CLIENT_COMMENT=test CLIENT_EMAIL=test CLIENT_UUID=11111111-2222-4333-8444-555555555555
  CLIENT_SUBID=test REALITY_PRIVATE_KEY=test REALITY_PUBLIC_KEY=test
  SID_PRIMARY=abcd SID_EXTRA_1=01 SID_EXTRA_2=02 SID_EXTRA_3=03
  SID_EXTRA_4=04 SID_EXTRA_5=05 SID_EXTRA_6=06 SID_EXTRA_7=07
  create_vless_reality_payload || return 1
  grep -Fq '\"minClientVer\":\"1.8.1\"' "$TEST_TMP/inbound-vless-reality.json"
)
assert_success "Reality payload explicitly accepts sing-box client version" reality_payload_accepts_sing_box

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
assert_eq "v3.9.0" "$WARREN_3XUI_RELEASE_TAG" "3x-ui release tag is applied by default"
assert_eq "18616fe26c8f6c92db6daa2dcd7cd53c5143ee69ecfd26d8ea6dc9b2c78607a6" \
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

assert_eq "0-17, 99" "$(warren_menu_range)" "menu prompt range is derived from the registry"
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

# Mac-side list backup/restore (tools/warren-settings.sh): parse, snapshot, uci batch.
SETTINGS_DIR="$TEST_TMP/settings"
mkdir -p "$SETTINGS_DIR"
cat > "$SETTINGS_DIR/router.uci" <<'SETTINGS_EOF'
config settings 'settings'
	option dns_type 'doh'
	list source_network_interfaces 'br-lan'
	list routing_excluded_ips '192.168.1.188'

config section 'main'
	option connection_type 'proxy'
	option user_domain_list_type 'dynamic'
	list community_lists 'cloudflare'
	list user_domains 'github.com'
	list user_domains 'o'\''reilly.com'
	list fully_routed_ips '192.168.1.137'
	list urltest_proxy_links 'vless://secret@1.2.3.4:443'

config section 'Exclusion'
	option connection_type 'exclusion'
	list user_domains 'gosuslugi.ru'
SETTINGS_EOF

cat > "$SETTINGS_DIR/live.uci" <<'SETTINGS_EOF'
config settings 'settings'
	option dns_type 'doh'

config section 'main'
	option connection_type 'proxy'
	list user_domains 'only-on-router.example'
SETTINGS_EOF

settings_tool() {
  WARREN_SETTINGS_LIB_ONLY=1 sh -c '
    set -eu
    . "$1/tools/warren-settings.sh"
    WS_TMP="$2/tmp"
    mkdir -p "$WS_TMP"
    shift 2
    "$@"
  ' _ "$PROJECT_DIR" "$SETTINGS_DIR" "$@"
}

settings_build_snapshot() {
  rm -rf "$SETTINGS_DIR/snap" "$SETTINGS_DIR/tmp"
  mkdir -p "$SETTINGS_DIR/snap"
  WARREN_SETTINGS_LIB_ONLY=1 sh -c '
    set -eu
    . "$1/tools/warren-settings.sh"
    WS_TMP="$2/tmp"
    mkdir -p "$WS_TMP"
    warren_settings_parse_export < "$2/router.uci" > "$WS_TMP/router.tsv"
    warren_settings_parse_export < "$2/live.uci" > "$WS_TMP/live.tsv"
    warren_settings_write_lists "$WS_TMP/router.tsv" "$2/snap"
  ' _ "$PROJECT_DIR" "$SETTINGS_DIR"
}
assert_success "settings backup builds a snapshot from uci export" settings_build_snapshot

assert_eq "list	main	section	user_domains	2" \
  "$(awk -F'\t' '$1 == "main.user_domains.txt" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' \
     "$SETTINGS_DIR/snap/lists/index.tsv")" \
  "user domain list is captured with its section and kind"

assert_eq "192.168.1.188" "$(cat "$SETTINGS_DIR/snap/lists/settings.routing_excluded_ips.txt")" \
  "podkop bypass IPs are captured"

assert_eq "gosuslugi.ru" "$(cat "$SETTINGS_DIR/snap/lists/Exclusion.user_domains.txt")" \
  "extra sections (Exclusion) keep their own lists"

assert_eq "o'reilly.com" "$(sed -n '2p' "$SETTINGS_DIR/snap/lists/main.user_domains.txt")" \
  "quoted values are unescaped on save"

settings_no_secrets_in_snapshot() {
  ! grep -rq "urltest_proxy_links\|source_network_interfaces" "$SETTINGS_DIR/snap/lists/"
}
assert_success "proxy links and Warren-managed interfaces stay out of the list backup" \
  settings_no_secrets_in_snapshot

settings_commands() {
  settings_tool warren_settings_restore_commands "$SETTINGS_DIR/snap" "$SETTINGS_DIR/tmp/live.tsv" "$1"
}

assert_eq "1" "$(settings_commands replace | grep -c "^set podkop.Exclusion=section$")" \
  "a missing section is created once"

assert_eq "set podkop.Exclusion.connection_type='exclusion'" \
  "$(settings_commands replace | sed -n '2p')" \
  "a created section gets its connection_type back"

assert_eq "add_list podkop.main.user_domains='o'\''reilly.com'" \
  "$(settings_commands replace | grep "reilly")" \
  "values are re-quoted for uci batch"

assert_eq "0" "$(settings_commands replace | grep -c "only-on-router.example")" \
  "replace mode drops entries that are only on the router"

assert_eq "1" "$(settings_commands merge | grep -c "only-on-router.example")" \
  "merge mode keeps entries that are only on the router"

assert_eq "set podkop.main.user_domain_list_type='dynamic'" \
  "$(settings_commands replace | grep "user_domain_list_type")" \
  "scalar list-type options are restored with set, not add_list"

settings_plan_reports_diff() {
  settings_tool warren_settings_plan "$SETTINGS_DIR/snap" "$SETTINGS_DIR/tmp/live.tsv" replace |
    grep -q "podkop.main.user_domains: .* (+2 / -1)"
}
assert_success "restore plan counts additions and removals per option" settings_plan_reports_diff

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

watchdog_skips_self_recovered_podkop() {
  rm -rf "$WATCHDOG_RESTARTS" "$WARREN_WATCHDOG_STATE" "$WATCHDOG_PROC"
  mkdir -p "$WATCHDOG_PROC"
  sleep_bin="$TEST_TMP/watchdog-sleep-bin"; mkdir -p "$sleep_bin"
  # The engine comes back while the watchdog waits RESTART_DELAY.
  cat > "$sleep_bin/sleep" <<'EOF'
#!/bin/sh
mkdir -p "$PODKOP_HEALTH_PROC/4343" && printf "sing-box\n" > "$PODKOP_HEALTH_PROC/4343/comm"
EOF
  chmod +x "$sleep_bin/sleep"
  printf "WARREN_WATCHDOG_RESTART_DELAY=5\n" > "$TEST_TMP/watchdog-delay.conf"
  PATH="$sleep_bin:$WATCHDOG_TEST_BIN:$PATH" \
  WARREN_TEST_WATCHDOG_RESTARTS="$WATCHDOG_RESTARTS" \
  WARREN_WATCHDOG_CONF="$TEST_TMP/watchdog-delay.conf" \
  WARREN_WATCHDOG_STATE="$WARREN_WATCHDOG_STATE" \
  WARREN_WATCHDOG_PODKOP_INIT="$WATCHDOG_TEST_BIN/podkop-init" \
  WARREN_WATCHDOG_HEALTH="$PODKOP_HEALTH_BIN" \
  PODKOP_HEALTH_PROC="$WATCHDOG_PROC" \
    "$WARREN_WATCHDOG_BIN" run-once
  grep -q "^STATUS=healthy$" "$WARREN_WATCHDOG_STATE" && [ ! -e "$WATCHDOG_RESTARTS" ]
}
assert_success "Podkop Watchdog does not restart a Podkop that recovered during the delay" watchdog_skips_self_recovered_podkop

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

# --- TG bot: Корп-VPN (vivpn) ------------------------------------------------
TG_BOT_BIN="$PROJECT_DIR/payload/warren-tg-bot"
CORP_TMP="$TEST_TMP/corp"
mkdir -p "$CORP_TMP"

CORP_DNSMASQ="$CORP_TMP/dnsmasq.conf"
cat > "$CORP_DNSMASQ" <<'EOF'
# corp-vpn-gateway
server=/vpn.example.com/8.8.8.8
# corp-vpn-dns: корп-имена резолвим через DNS, приехавший по туннелю.
server=/wiki.example.com/10.242.112.11
server=/wiki.example.com/10.242.112.12
server=/jira.example.com/10.242.112.11
rebind-domain-ok=/wiki.example.com/jira.example.com/
# end corp-vpn-dns
EOF

# Заглушка vivpn: пишет свои аргументы в файл, печатает цветную строку,
# как настоящий, и читает stdin — так видно зависание, если бот его не закроет.
CORP_FAKE_VIVPN="$CORP_TMP/vivpn"
cat > "$CORP_FAKE_VIVPN" <<'EOF'
#!/bin/sh
printf "%s\n" "$*" > "$VIVPN_ARGS_FILE"
printf '  \033[0;32m✓\033[0m  готово: %s\n' "$*"
read -r _ignored
exit "${VIVPN_FAKE_RC:-0}"
EOF
chmod +x "$CORP_FAKE_VIVPN"

corp_bot_env() {
  WARREN_TG_BOT_LIB_ONLY=1 \
  WARREN_TG_BOT_VIVPN="$CORP_FAKE_VIVPN" \
  WARREN_TG_BOT_CORP_DNSCONF="$CORP_DNSMASQ" \
  VIVPN_ARGS_FILE="$CORP_TMP/args" \
    sh -c '. "$1"; eval "$2"' sh "$TG_BOT_BIN" "$1"
}

assert_success "TG bot sources cleanly in library-only mode" \
  env WARREN_TG_BOT_LIB_ONLY=1 sh -c '. "$1"' sh "$TG_BOT_BIN"

assert_eq "wiki.example.com jira.example.com" \
  "$(corp_bot_env 'corp_dns_names | tr "\n" " " | sed "s/ $//"')" \
  "TG bot reads corp DNS names from the dnsmasq block only"

assert_eq "  ✓  готово: status" \
  "$(printf '  \033[0;32m✓\033[0m  готово: status\n' | corp_bot_env 'strip_ansi')" \
  "TG bot strips ANSI colours out of vivpn output"

corp_run_captures_output_and_code() {
  out="$(corp_bot_env 'export VIVPN_FAKE_RC=3; corp_run up; printf "rc=%s out=%s" "$?" "$CORP_OUT"')"
  [ "$out" = "rc=3 out=  ✓  готово: up" ]
}
assert_success "TG bot keeps the vivpn exit code and closes its stdin" corp_run_captures_output_and_code

corp_dns_del_uses_the_name_behind_the_index() {
  corp_bot_env 'corp_dns_del_index 2' >/dev/null 2>&1 || true
  [ "$(cat "$CORP_TMP/args" 2>/dev/null)" = "dns del jira.example.com" ]
}
assert_success "TG bot deletes the corp DNS name that the button index points at" \
  corp_dns_del_uses_the_name_behind_the_index

corp_dns_add_rejects_a_bare_word() {
  corp_bot_env 'corp_dns_add_name wiki'
  [ "$?" -eq 3 ]
}
assert_success "TG bot refuses a corp DNS entry that is not a full name" corp_dns_add_rejects_a_bare_word

corp_available_follows_the_vivpn_binary() {
  corp_bot_env 'corp_available' || return 1
  WARREN_TG_BOT_LIB_ONLY=1 WARREN_TG_BOT_VIVPN="$CORP_TMP/absent" \
    sh -c '. "$1"; corp_available' sh "$TG_BOT_BIN" && return 1
  return 0
}
assert_success "TG bot hides Корп-VPN when vivpn is not installed" corp_available_follows_the_vivpn_binary

every_corp_button_has_a_handler() {
  grep -o 'callback_data:"corp[a-z_]*"' "$TG_BOT_BIN" |
    sed 's/.*callback_data:"//; s/"//' | sort -u |
    while IFS= read -r cb; do
      [ -n "$cb" ] || continue
      grep -q "^    ${cb})" "$TG_BOT_BIN" || {
        printf "no handler for callback %s\n" "$cb" >&2
        exit 1
      }
    done
}
assert_success "every Корп-VPN button has a callback handler in the TG bot" \
  every_corp_button_has_a_handler

# Регрессия: пустое поле в середине TSV съедалось IFS=<tab> в ash, и
# callback_data приезжала в message_id — все кнопки отвечали "Неизвестная кнопка".
cat > "$CORP_TMP/updates.json" <<'EOF'
{"result":[
 {"update_id":10,"callback_query":{"id":"CB1","data":"corp_menu","message":{"chat":{"id":4242}}}},
 {"update_id":11,"message":{"message_id":77,"chat":{"id":4242},"text":"wiki.example.com"}}
]}
EOF

parse_update_field() {
  wanted_kind="$1"
  wanted_field="$2"
  corp_bot_env "updates_tsv_filter" > "$CORP_TMP/filter.jq"
  jq -r -f "$CORP_TMP/filter.jq" < "$CORP_TMP/updates.json" |
    while IFS='	' read -r update_id kind chat_id callback_id message_id payload; do
      [ "$kind" = "$wanted_kind" ] || continue
      [ "$callback_id" != "-" ] || callback_id=""
      [ "$message_id" != "-" ] || message_id=""
      case "$wanted_field" in
        callback_id) printf "%s" "$callback_id" ;;
        message_id)  printf "%s" "$message_id" ;;
        payload)     printf "%s" "$payload" ;;
        chat_id)     printf "%s" "$chat_id" ;;
      esac
      return 0
    done
}

if command -v jq >/dev/null 2>&1; then
  assert_eq "corp_menu" "$(parse_update_field callback payload)" \
    "TG bot keeps callback_data in the payload field"
  assert_eq "CB1" "$(parse_update_field callback callback_id)" \
    "TG bot keeps the callback id"
  assert_eq "" "$(parse_update_field callback message_id)" \
    "TG bot leaves message_id empty for a callback"
  assert_eq "wiki.example.com" "$(parse_update_field message payload)" \
    "TG bot keeps message text in the payload field"
  assert_eq "77" "$(parse_update_field message message_id)" \
    "TG bot keeps the message id so an OTP message can be deleted"
  assert_eq "" "$(parse_update_field message callback_id)" \
    "TG bot leaves callback_id empty for a message"
else
  printf "# jq not installed, skipping TG bot update-parsing tests\n"
fi

printf "\nPassed: %d  Failed: %d\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
