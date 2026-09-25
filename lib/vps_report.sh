# VPS report files on the router: paths, fields, selection for Podkop, TG notice.

vps_sanitized_host() {
  printf "%s" "${VPS_HOST:-unknown}" | tr -c 'A-Za-z0-9._-' '_'
}

vps_workspace_dir() {
  conf_dir="$(dirname "$CONF")"
  printf "%s" "${WARREN_VPS_DIR:-${conf_dir}/vps}"
}

vps_keys_dir() {
  printf "%s/keys" "$(vps_workspace_dir)"
}

vps_reports_dir() {
  printf "%s/reports" "$(vps_workspace_dir)"
}

vps_report_file() {
  printf "%s/%s.txt" "$(vps_reports_dir)" "$(vps_sanitized_host)"
}

vps_report_files() {
  reports_dir="$(vps_reports_dir)"
  [ -d "$reports_dir" ] || return 0
  ls -1t "$reports_dir"/*.txt 2>/dev/null || true
}

vps_report_vless_link() {
  report_file="$1"
  [ -r "$report_file" ] || return 1
  sed -n 's/^VLESS inbound link: //p' "$report_file" | head -n1
}

vps_report_field() {
  report_file="$1"
  field_name="$2"
  [ -r "$report_file" ] || return 1
  sed -n "s/^${field_name}: //p" "$report_file" | head -n1
}

vps_report_host() {
  vps_report_field "$1" "Host"
}

vps_report_ssh_port() {
  vps_report_field "$1" "SSH port"
}

vps_report_root_password() {
  vps_report_field "$1" "SSH root password"
}

vps_report_vless_sni() {
  report_file="$1"
  vless_link="$(vps_report_vless_link "$report_file")" || return 1
  printf "%s\n" "$vless_link" | sed -n 's/.*[?&]sni=\([^&]*\).*/\1/p' | head -n1
}

vps_report_summary_text() {
  report_file="$1"
  [ -r "$report_file" ] || return 1
  printf "Новый VPS Warren\n\n"
  printf "Host: %s\n" "$(vps_report_host "$report_file" || printf "unknown")"
  printf "SSH: root@%s:%s\n" \
    "$(vps_report_host "$report_file" || printf "unknown")" \
    "$(vps_report_ssh_port "$report_file" || printf "22")"
  printf "Root password: %s\n" "$(vps_report_root_password "$report_file" || printf "unknown")"
  printf "3x-ui URL: %s\n" "$(vps_report_field "$report_file" "3x-ui URL" || printf "unknown")"
  printf "3x-ui login: %s\n" "$(vps_report_field "$report_file" "3x-ui username" || printf "unknown")"
  printf "3x-ui password: %s\n" "$(vps_report_field "$report_file" "3x-ui password" || printf "unknown")"
  printf "VLESS: %s\n" "$(vps_report_vless_link "$report_file" || printf "unknown")"
  printf "Report: %s\n" "$report_file"
}

notify_vps_report_via_tg() {
  report_file="$1"
  tg_conf="${WARREN_BASE_DIR:-/etc/warren}/warren-tg-bot.conf"
  [ -r "$report_file" ] || return 0
  [ -r "$tg_conf" ] || return 0

  TG_TOKEN=""
  ALLOWED_CHAT_ID=""
  # shellcheck disable=SC1090
  . "$tg_conf"

  [ -n "${TG_TOKEN:-}" ] || return 0
  [ -n "${ALLOWED_CHAT_ID:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  api="https://api.telegram.org/bot${TG_TOKEN}"
  summary_text="$(vps_report_summary_text "$report_file")"

  curl -fsS -X POST "${api}/sendMessage" \
    -d "chat_id=${ALLOWED_CHAT_ID}" \
    --data-urlencode "text=${summary_text}" >/dev/null 2>&1 || return 0

  curl -fsS -X POST "${api}/sendDocument" \
    -F "chat_id=${ALLOWED_CHAT_ID}" \
    -F "document=@${report_file}" \
    -F "caption=Последний VPS-отчёт Warren" >/dev/null 2>&1 || true
}

select_vps_report_for_podkop() {
  report_list="$(vps_report_files)"
  report_count="$(printf "%s\n" "$report_list" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "${report_count:-0}" -eq 0 ]; then
    return 1
  fi

  if [ "$report_count" -eq 1 ]; then
    SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n '1p')"
    VLESS="$(vps_report_vless_link "$SELECTED_VPS_REPORT")"
    [ -n "$VLESS" ] || fail "Не удалось прочитать VLESS из отчёта VPS: $SELECTED_VPS_REPORT"
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    conf_set VLESS "$VLESS"
    runtime_state_set "selected_vps_report" "$SELECTED_VPS_REPORT"
    runtime_state_set "vless" "$VLESS"
    say "${GREEN}DONE${NC}  Найден один VPS-отчёт, использую его для Podkop: $SELECTED_VPS_REPORT"
    return 0
  fi

  say ""
  say "Найдено несколько VPS-отчётов. Выбери, какой использовать для Podkop:"
  report_index=1
  printf "%s\n" "$report_list" | while IFS= read -r report_file; do
    [ -n "$report_file" ] || continue
    report_name="$(basename "$report_file" .txt)"
    say "$report_index) $report_name"
    report_index=$((report_index + 1))
  done
  ask "Выбор VPS для Podkop" REPORT_CHOICE "1"

  case "$REPORT_CHOICE" in
    ''|*[!0-9]*)
      fail "Введи номер VPS-отчёта"
      ;;
  esac
  [ "$REPORT_CHOICE" -ge 1 ] && [ "$REPORT_CHOICE" -le "$report_count" ] || fail "Нет VPS-отчёта с номером $REPORT_CHOICE"

  SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n "${REPORT_CHOICE}p")"
  [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось определить выбранный VPS-отчёт"
  VLESS="$(vps_report_vless_link "$SELECTED_VPS_REPORT")"
  [ -n "$VLESS" ] || fail "Не удалось прочитать VLESS из отчёта VPS: $SELECTED_VPS_REPORT"

  conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
  conf_set VLESS "$VLESS"
  runtime_state_set "selected_vps_report" "$SELECTED_VPS_REPORT"
  runtime_state_set "vless" "$VLESS"
  say "${GREEN}DONE${NC}  Для Podkop выбран VPS-отчёт: $SELECTED_VPS_REPORT"
  return 0
}
