get_state() {
  [ -f "$STATE" ] && cat "$STATE" || echo "0"
}

json_escape() {
  printf "%s" "$1" | awk 'BEGIN { ORS=""; first=1 } {
    if (!first) printf "\\n";
    gsub(/\\/,"\\\\");
    gsub(/"/,"\\\"");
    printf "%s", $0;
    first=0
  }'
}

set_state() {
  echo "$1" > "$STATE"
  sync
}

load_conf_if_exists() {
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    normalize_mode
    return 0
  fi
  return 1
}

save_conf() {
  {
    printf "MODE=%s\n" "$(quote_sh "${MODE:-}")"
    printf "VLESS=%s\n" "$(quote_sh "${VLESS:-}")"
    printf "LIST_RU=%s\n" "$(quote_sh "${LIST_RU:-}")"
    printf "LIST_CF=%s\n" "$(quote_sh "${LIST_CF:-}")"
    printf "LIST_META=%s\n" "$(quote_sh "${LIST_META:-}")"
    printf "LIST_GOOGLE_AI=%s\n" "$(quote_sh "${LIST_GOOGLE_AI:-}")"
    printf "WG_ENDPOINT=%s\n" "$(quote_sh "${WG_ENDPOINT:-}")"
    printf "VPS_HOST=%s\n" "$(quote_sh "${VPS_HOST:-}")"
    printf "VPS_SSH_PORT=%s\n" "$(quote_sh "${VPS_SSH_PORT:-}")"
    printf "SELECTED_VPS_REPORT=%s\n" "$(quote_sh "${SELECTED_VPS_REPORT:-}")"
  } > "$CONF"
}

conf_set() {
  key="$1"
  val="$2"

  case "$key" in
    MODE|VLESS|LIST_RU|LIST_CF|LIST_META|LIST_GOOGLE_AI|WG_ENDPOINT|VPS_HOST|VPS_SSH_PORT|SELECTED_VPS_REPORT) ;;
    *) fail "Неизвестный ключ конфига: $key" ;;
  esac

  eval "$key=$(quote_sh "$val")"
  save_conf
}

init_runtime_state() {
  : > "$AUTO_STATE_STORE"
  printf "{\n}\n" > "$AUTO_STATE_JSON"
}

render_runtime_state_json() {
  {
    printf "{\n"
    first=1
    if [ -f "$AUTO_STATE_STORE" ]; then
      while IFS='	' read -r key val; do
        [ -n "$key" ] || continue
        [ "$first" -eq 1 ] || printf ",\n"
        printf '  "%s": "%s"' "$(json_escape "$key")" "$(json_escape "$val")"
        first=0
      done < "$AUTO_STATE_STORE"
    fi
    printf "\n}\n"
  } > "$AUTO_STATE_JSON"
}

runtime_state_set() {
  key="$1"
  val="$2"
  tmp="${AUTO_STATE_STORE}.tmp"

  touch "$AUTO_STATE_STORE"
  grep -v "^${key}	" "$AUTO_STATE_STORE" > "$tmp" 2>/dev/null || true
  printf "%s	%s\n" "$key" "$val" >> "$tmp"
  mv "$tmp" "$AUTO_STATE_STORE"
  render_runtime_state_json
}

capture_runtime_inputs() {
  init_runtime_state
  runtime_state_set "mode" "${MODE:-}"
  runtime_state_set "vless" "${VLESS:-}"
  runtime_state_set "list_ru" "${LIST_RU:-}"
  runtime_state_set "list_cf" "${LIST_CF:-}"
  runtime_state_set "list_meta" "${LIST_META:-}"
  runtime_state_set "list_google_ai" "${LIST_GOOGLE_AI:-}"
  runtime_state_set "wg_endpoint" "${WG_ENDPOINT:-}"
  runtime_state_set "vps_host" "${VPS_HOST:-}"
  runtime_state_set "vps_ssh_port" "${VPS_SSH_PORT:-}"
  runtime_state_set "selected_vps_report" "${SELECTED_VPS_REPORT:-}"
}

cleanup_runtime_state() {
  rm -f "$AUTO_STATE_JSON" "$AUTO_STATE_STORE" "${AUTO_STATE_STORE}.tmp" 2>/dev/null || true
}

normalize_mode() {
  case "${MODE:-}" in
    0) MODE="basic" ;;
    1) MODE="podkop_setup" ;;
    2) MODE="add_private" ;;
    3) MODE="add_private" ;;
    4) MODE="manage_private" ;;
  esac
}

load_conf() {
  [ -f "$CONF" ] || menu
  load_conf_if_exists || menu
}
