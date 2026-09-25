#!/bin/sh
# Podkop runtime health probes: the only implementation.
#   sourced  by lib/podkop.sh (shell flows, diagnostics) and the watchdog worker;
#   executed by LuCI: sh podkop-health.sh snapshot
# Installed to /usr/libexec/warren/podkop-health.sh. POSIX sh, no Warren libs.

PODKOP_INIT_SCRIPT="${PODKOP_INIT_SCRIPT:-/etc/init.d/podkop}"
PODKOP_HEALTH_PROC="${PODKOP_HEALTH_PROC:-/proc}"

podkop_is_installed() {
  [ -x "$PODKOP_INIT_SCRIPT" ] || command -v podkop >/dev/null 2>&1
}

podkop_init_running() {
  [ -x "$PODKOP_INIT_SCRIPT" ] && "$PODKOP_INIT_SCRIPT" status >/dev/null 2>&1
}

# Exact process name via /proc/<pid>/comm: BusyBox `pgrep -x` gave false
# negatives for a live sing-box on R5S.
podkop_engine_running() {
  for _ph_comm in "$PODKOP_HEALTH_PROC"/[0-9]*/comm; do
    [ -r "$_ph_comm" ] || continue
    IFS= read -r _ph_name < "$_ph_comm" || _ph_name=""
    case "$_ph_name" in
      sing-box|xray) return 0 ;;
    esac
  done
  [ "$PODKOP_HEALTH_PROC" = "/proc" ] || return 1
  ps w 2>/dev/null | grep -Eq '[/](sing-box|xray)([[:space:]]|$)'
}

podkop_config_ok() {
  _ph_primary="${PODKOP_CONFIG_PATH:-/etc/sing-box/config.json}"
  _ph_fallback="${PODKOP_CONFIG_FALLBACK_PATH:-/tmp/etc/sing-box/config.json}"

  if [ -s "$_ph_primary" ]; then
    if command -v sing-box >/dev/null 2>&1; then
      ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true sing-box check -c "$_ph_primary" >/dev/null 2>&1
      return $?
    fi
    return 0
  fi

  [ -s "$_ph_fallback" ]
}

podkop_rules_active() {
  command -v ip >/dev/null 2>&1 || return 1
  ip rule show 2>/dev/null | grep -Eqi 'podkop|tproxy|fwmark|0x2023|mark'
}

podkop_nft_active() {
  command -v nft >/dev/null 2>&1 || return 1
  nft list ruleset 2>/dev/null | grep -Eqi 'podkop|sing-box|tproxy|0x2023|dns_redirect|mangle'
}

# One line: health=ok|warn|bad init= engine= config= rules= nft= evidence=
podkop_runtime_snapshot() {
  _ph_init=0
  _ph_engine=0
  _ph_config=0
  _ph_rules=0
  _ph_nft=0
  _ph_evidence=0
  _ph_health=bad

  podkop_init_running && _ph_init=1
  if podkop_engine_running; then
    _ph_engine=1
    _ph_evidence=$((_ph_evidence + 1))
  fi
  if podkop_config_ok; then
    _ph_config=1
    _ph_evidence=$((_ph_evidence + 1))
  fi
  if podkop_rules_active; then
    _ph_rules=1
    _ph_evidence=$((_ph_evidence + 1))
  fi
  if podkop_nft_active; then
    _ph_nft=1
    _ph_evidence=$((_ph_evidence + 1))
  fi

  if [ "$_ph_init" = "1" ]; then
    _ph_health=ok
  elif [ "$_ph_engine" = "1" ] && [ "$_ph_evidence" -ge 3 ]; then
    _ph_health=warn
  fi

  printf "health=%s init=%s engine=%s config=%s rules=%s nft=%s evidence=%s\n" \
    "$_ph_health" "$_ph_init" "$_ph_engine" "$_ph_config" \
    "$_ph_rules" "$_ph_nft" "$_ph_evidence"
}

podkop_runtime_field() {
  printf "%s\n" "$1" | tr ' ' '\n' | sed -n "s/^${2}=//p" | sed -n '1p'
}

podkop_runtime_healthy() {
  _ph_snapshot="${1:-$(podkop_runtime_snapshot)}"
  case "$(podkop_runtime_field "$_ph_snapshot" health)" in
    ok|warn) return 0 ;;
    *) return 1 ;;
  esac
}

# Cheap check for the watchdog loop (no `sing-box check`): prints the reason,
# succeeds only when healthy.
podkop_health_reason() {
  podkop_engine_running || {
    printf "%s" "sing-box-not-running"
    return 1
  }
  podkop_rules_active || {
    printf "%s" "podkop-rules-missing"
    return 1
  }
  printf "%s" "healthy"
}

case "${0##*/}" in
  podkop-health.sh)
    case "${1:-snapshot}" in
      snapshot) podkop_runtime_snapshot ;;
      reason) podkop_health_reason; echo ;;
      *) printf "usage: %s [snapshot|reason]\n" "$0" >&2; exit 2 ;;
    esac
    ;;
esac
