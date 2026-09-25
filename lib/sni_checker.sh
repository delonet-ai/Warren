sni_checker_router_dir() {
  printf "%s/sni-checker" "${WARREN_BASE_DIR:-/etc/warren}"
}

sni_checker_router_candidates_file() {
  printf "%s/sni-candidates.txt" "$(sni_checker_router_dir)"
}

sni_checker_router_script_file() {
  printf "%s/check-sni.sh" "$(sni_checker_router_dir)"
}

sni_checker_router_reports_dir() {
  printf "%s/reports" "$(sni_checker_router_dir)"
}

sni_checker_remote_dir() {
  printf "%s" "/root/sni-checker"
}

sni_checker_remote_candidates_file() {
  printf "%s/sni-candidates.txt" "$(sni_checker_remote_dir)"
}

sni_checker_remote_script_file() {
  printf "%s/check-sni.sh" "$(sni_checker_remote_dir)"
}

sni_checker_report_basename() {
  printf "%s" "${1##*/}"
}

sni_checker_backups_dir() {
  printf "%s/backups" "$(sni_checker_router_dir)"
}

sni_checker_ensure_router_layout() {
  mkdir -p "$(sni_checker_router_dir)" "$(sni_checker_router_reports_dir)" "$(sni_checker_backups_dir)" || fail "Не удалось создать каталог SNI-checker на роутере"
}

sni_checker_ensure_candidates_file() {
  candidates_file="$(sni_checker_router_candidates_file)"
  [ -f "$candidates_file" ] && return 0

  asset_file="$(fetch_asset "sni-candidates.txt")"
  cp "$asset_file" "$candidates_file" || fail "Не удалось подготовить список SNI-кандидатов на роутере"
  chmod 600 "$candidates_file" 2>/dev/null || true
}

sni_checker_select_vps_report() {
  report_list="$(vps_report_files)"
  report_count="$(printf "%s\n" "$report_list" | sed '/^$/d' | wc -l | tr -d ' ')"

  [ "${report_count:-0}" -gt 0 ] || fail "Не найдено VPS-отчётов в $(vps_reports_dir). Сначала настрой VPS через Warren."

  if [ -n "${SELECTED_VPS_REPORT:-}" ] && [ -r "${SELECTED_VPS_REPORT:-}" ]; then
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    return 0
  fi

  if [ "${WARREN_LUCI_REQUEST:-0}" = "1" ]; then
    SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed '/^$/d' | head -n1)"
    [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось выбрать VPS-отчёт для SNI-checker"
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    say "${GREEN}DONE${NC}  SNI-checker выбрал VPS-отчёт: $(basename "$SELECTED_VPS_REPORT" .txt)"
    return 0
  fi

  if [ "$report_count" -eq 1 ]; then
    SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n '1p')"
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    return 0
  fi

  say ""
  say "Выбери VPS для проверки SNI-кандидатов:"
  report_index=1
  printf "%s\n" "$report_list" | while IFS= read -r report_file; do
    [ -n "$report_file" ] || continue
    say "$report_index) $(basename "$report_file" .txt)"
    report_index=$((report_index + 1))
  done
  ask "Выбор VPS" SNI_REPORT_CHOICE "1"

  case "$SNI_REPORT_CHOICE" in
    ''|*[!0-9]*) fail "Введи номер VPS-отчёта" ;;
  esac
  [ "$SNI_REPORT_CHOICE" -ge 1 ] && [ "$SNI_REPORT_CHOICE" -le "$report_count" ] || fail "Нет VPS-отчёта с номером $SNI_REPORT_CHOICE"

  SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n "${SNI_REPORT_CHOICE}p")"
  [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось определить выбранный VPS-отчёт"
  conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
}

sni_checker_load_vps_report() {
  report_file="$1"
  [ -r "$report_file" ] || fail "Не найден VPS-отчёт: $report_file"

  VPS_HOST="$(vps_report_host "$report_file")"
  VPS_SSH_PORT="$(vps_report_ssh_port "$report_file")"
  VPS_ROOT_PASSWORD="$(vps_report_root_password "$report_file")"
  CURRENT_SNI="$(vps_report_vless_sni "$report_file")"

  [ -n "$VPS_HOST" ] || fail "В VPS-отчёте не найден Host"
  [ -n "$VPS_SSH_PORT" ] || VPS_SSH_PORT="22"
  [ "$VPS_ROOT_PASSWORD" = "unknown" ] && VPS_ROOT_PASSWORD=""
  [ -n "$CURRENT_SNI" ] || CURRENT_SNI="vk.ru"

  runtime_state_set "selected_vps_report" "$report_file"
  runtime_state_set "vps_host" "$VPS_HOST"
  runtime_state_set "vps_ssh_port" "$VPS_SSH_PORT"
  runtime_state_set "current_sni" "$CURRENT_SNI"
}

sni_checker_try_existing_key() {
  VPS_KEY_PATH=""
  host_key_prefix="$(vps_sanitized_host)"
  candidate_key="$(find "$(vps_keys_dir)" -maxdepth 1 -type f \( -name "${host_key_prefix}_ed25519" -o -name "${host_key_prefix}_*_ed25519" \) | head -n1)"
  [ -n "$candidate_key" ] || return 1

  VPS_KEY_PATH="$candidate_key"
  if vps_ssh_key_timeout 20 "printf '__WARREN_SNI_KEY_OK__\n'" 2>/dev/null | grep -q "__WARREN_SNI_KEY_OK__"; then
    runtime_state_set "vps_key_path" "$VPS_KEY_PATH"
    return 0
  fi

  VPS_KEY_PATH=""
  return 1
}

sni_checker_verify_vps_access() {
  info "Готовлю подключение к VPS для SNI-checker..."
  ensure_vps_prereqs
  mkdir -p "$(vps_workspace_dir)" "$(vps_keys_dir)" || fail "Не удалось подготовить каталог ключей Warren"

  if sni_checker_try_existing_key; then
    say "${GREEN}DONE${NC}  Найден рабочий SSH-ключ Warren для $VPS_HOST"
    return 0
  fi

  [ -n "${VPS_ROOT_PASSWORD:-}" ] || fail "В VPS-отчёте нет root-пароля, а рабочий SSH-ключ не найден"
  out="$(vps_ssh_password_timeout 20 "printf '__WARREN_SNI_PASS_OK__\n'")" || fail "Не удалось подключиться к VPS по SSH для SNI-checker"
  printf "%s" "$out" | grep -q "__WARREN_SNI_PASS_OK__" || fail "VPS ответил неожиданно при проверке SSH"
  say "${GREEN}DONE${NC}  SSH-доступ к VPS подтверждён"
}

sni_checker_write_local_script() {
  local_script="$(sni_checker_router_script_file)"
  mkdir -p "$(dirname "$local_script")" || fail "Не удалось создать каталог для локального check-sni.sh"
  warren_install_payload check-sni.sh "$local_script"
  chmod 700 "$local_script" || fail "Не удалось сделать локальный check-sni.sh исполняемым"
}

sni_checker_show_local_script() {
  local_script="$(sni_checker_router_script_file)"
  say ""
  say "SNI-checker ничего не меняет на VPS:"
  say "- не перезапускает 3x-ui/Xray"
  say "- не меняет конфиги Reality"
  say "- не трогает firewall"
  say "- только создаёт /root/sni-checker и запускает read-only проверки"
  say ""
  say "Файл на роутере: $(sni_checker_router_candidates_file)"
  say "Файлы на VPS: $(sni_checker_remote_script_file) и $(sni_checker_remote_candidates_file)"
  say ""
  say "=== Содержимое check-sni.sh ==="
  sed -n '1,240p' "$local_script"
}

sni_checker_upload_files() {
  remote_dir="$(sni_checker_remote_dir)"
  local_script="$(sni_checker_router_script_file)"
  local_candidates="$(sni_checker_router_candidates_file)"

  vps_ssh_timeout 60 "mkdir -p $(quote_sh "$remote_dir")" || fail "Не удалось создать каталог $remote_dir на VPS"
  vps_write_remote_file "$local_script" "$(sni_checker_remote_script_file)" || fail "Не удалось загрузить check-sni.sh на VPS"
  vps_write_remote_file "$local_candidates" "$(sni_checker_remote_candidates_file)" || fail "Не удалось загрузить sni-candidates.txt на VPS"
  vps_ssh_timeout 30 "chmod 700 $(quote_sh "$(sni_checker_remote_script_file)")" || fail "Не удалось выставить chmod для check-sni.sh на VPS"
}

sni_checker_fetch_report() {
  remote_file="$1"
  local_file="$2"
  vps_ssh_timeout 60 "cat $(quote_sh "$remote_file")" > "$local_file" || fail "Не удалось скачать отчёт SNI-checker с VPS"
  chmod 600 "$local_file" 2>/dev/null || true
}

sni_checker_run_remote() {
  remote_script="$(sni_checker_remote_script_file)"
  remote_candidates="$(sni_checker_remote_candidates_file)"
  remote_output="$(vps_ssh_timeout 7200 "bash $(quote_sh "$remote_script") $(quote_sh "$remote_candidates") $(quote_sh "$CURRENT_SNI")")" \
    || fail "SNI-checker завершился с ошибкой на VPS"

  say ""
  printf "%s\n" "$remote_output"

  remote_csv="$(printf "%s\n" "$remote_output" | sed -n 's/^__WARREN_REPORT_CSV__ //p' | tail -n1)"
  remote_txt="$(printf "%s\n" "$remote_output" | sed -n 's/^__WARREN_REPORT_TXT__ //p' | tail -n1)"

  [ -n "$remote_csv" ] || fail "Не удалось определить путь к CSV-отчёту SNI-checker на VPS"
  [ -n "$remote_txt" ] || fail "Не удалось определить путь к TXT-отчёту SNI-checker на VPS"

  local_csv="$(sni_checker_router_reports_dir)/$(vps_sanitized_host)-$(sni_checker_report_basename "$remote_csv")"
  local_txt="$(sni_checker_router_reports_dir)/$(vps_sanitized_host)-$(sni_checker_report_basename "$remote_txt")"
  sni_checker_fetch_report "$remote_csv" "$local_csv"
  sni_checker_fetch_report "$remote_txt" "$local_txt"

  say ""
  say "${GREEN}DONE${NC}  SNI-checker завершён"
  say "Отчёт на VPS: $remote_txt"
  say "Отчёты на роутере:"
  say "- $local_txt"
  say "- $local_csv"
}

run_sni_checker_flow() {
  init_runtime_state
  runtime_state_set "mode" "sni_checker"

  sni_checker_ensure_router_layout
  sni_checker_ensure_candidates_file
  sni_checker_select_vps_report
  sni_checker_load_vps_report "$SELECTED_VPS_REPORT"
  sni_checker_verify_vps_access
  sni_checker_write_local_script
  sni_checker_show_local_script

  say ""
  if [ "${WARREN_LUCI_REQUEST:-0}" = "1" ]; then
    SNI_CHECKER_CONFIRM="y"
    info "LuCI-запуск: подтверждение SNI-checker выполнено автоматически."
  else
    ask "Загрузить и запустить SNI-checker на VPS? (y/n)" SNI_CHECKER_CONFIRM "y"
    case "$SNI_CHECKER_CONFIRM" in
      y|Y) ;;
      n|N) done_ "SNI-checker подготовлен, запуск отменён пользователем"; return 0 ;;
      *) fail "Введи y или n" ;;
    esac
  fi

  sni_checker_upload_files
  sni_checker_run_remote
}

sni_apply_validate_domain() {
  candidate="$1"
  printf "%s" "$candidate" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

sni_apply_latest_txt_report() {
  reports_dir="$(sni_checker_router_reports_dir)"
  [ -d "$reports_dir" ] || return 0
  ls -1t "$reports_dir"/*.txt 2>/dev/null | head -n1
}

sni_apply_best_from_report() {
  report_file="$1"
  [ -r "$report_file" ] || return 1
  sed -n 's/^Best candidate: \([^ ]*\) (GOOD.*/\1/p' "$report_file" | head -n1
}

sni_apply_current_status_from_report() {
  report_file="$1"
  current_sni="$2"
  [ -r "$report_file" ] || return 0
  awk -v prefix="Current SNI: ${current_sni} (" '
    index($0, prefix) == 1 {
      value = substr($0, length(prefix) + 1)
      sub(/[,)].*/, "", value)
      print value
      exit
    }
  ' "$report_file"
}

sni_apply_secondary_name() {
  domain="$1"
  case "$domain" in
    www.*) printf "%s" "$domain" ;;
    *) printf "www.%s" "$domain" ;;
  esac
}

sni_apply_replace_vless_sni() {
  link="$1"
  new_sni="$2"
  fragment=""
  base="$link"

  case "$link" in
    *\#*)
      base="${link%%#*}"
      fragment="#${link#*#}"
      ;;
  esac

  if printf "%s" "$base" | grep -q '[?&]sni='; then
    printf "%s%s" "$(printf "%s" "$base" | sed "s/\([?&]sni=\)[^&]*/\1${new_sni}/")" "$fragment"
    return 0
  fi

  case "$base" in
    *\?*) printf "%s&sni=%s%s" "$base" "$new_sni" "$fragment" ;;
    *) printf "%s?sni=%s%s" "$base" "$new_sni" "$fragment" ;;
  esac
}

sni_apply_load_panel_from_report() {
  report_file="$1"
  PANEL_URL="$(vps_report_field "$report_file" "3x-ui URL")"
  PANEL_USERNAME="$(vps_report_field "$report_file" "3x-ui username")"
  PANEL_PASSWORD="$(vps_report_field "$report_file" "3x-ui password")"
  PANEL_SCHEME="$(printf "%s" "$PANEL_URL" | sed -n 's#^\([^:]*\)://.*#\1#p')"
  PANEL_PORT="$(printf "%s" "$PANEL_URL" | sed -n 's#^[^:]*://[^:/]*:\([0-9][0-9]*\).*#\1#p')"
  PANEL_BASE_PATH="$(printf "%s" "$PANEL_URL" | sed -n 's#^[^:]*://[^/]*\(/.*\)$#\1#p')"
  PANEL_BASE_PATH="$(normalize_panel_base_path "$PANEL_BASE_PATH")"

  [ -n "$PANEL_USERNAME" ] || fail "В VPS-отчёте нет логина 3x-ui"
  [ -n "$PANEL_PASSWORD" ] || fail "В VPS-отчёте нет пароля 3x-ui"
  [ -n "$PANEL_PORT" ] || PANEL_PORT="2053"
  [ -n "$PANEL_SCHEME" ] || PANEL_SCHEME="https"
}

sni_apply_load_vless_materials() {
  link="$1"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(printf "%s\n" "$link" | sed -n 's/.*[?&]pbk=\([^&]*\).*/\1/p' | head -n1)}"
  SID_PRIMARY="${SID_PRIMARY:-$(printf "%s\n" "$link" | sed -n 's/.*[?&]sid=\([^&]*\).*/\1/p' | head -n1)}"
  CLIENT_UUID="${CLIENT_UUID:-$(printf "%s\n" "$link" | sed -n 's#^vless://\([^@]*\)@.*#\1#p' | head -n1)}"
  CLIENT_EMAIL="${CLIENT_EMAIL:-$(vps_report_field "$SELECTED_VPS_REPORT" "Client email" 2>/dev/null || true)}"
}

sni_apply_prepare_vps_context() {
  sni_checker_load_vps_report "$SELECTED_VPS_REPORT"
  sni_checker_verify_vps_access

  if remote_artifact_exists; then
    load_remote_artifact
  else
    sni_apply_load_panel_from_report "$SELECTED_VPS_REPORT"
  fi

  VLESS_LINK="$(vps_report_vless_link "$SELECTED_VPS_REPORT")"
  [ -n "$VLESS_LINK" ] || fail "В VPS-отчёте нет VLESS inbound link"
  sni_apply_load_vless_materials "$VLESS_LINK"
}

sni_apply_choose_report() {
  report_list="$(vps_report_files)"
  report_count="$(printf "%s\n" "$report_list" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "${report_count:-0}" -gt 0 ] || fail "Не найдено VPS-отчётов в $(vps_reports_dir). Сначала настрой VPS через Warren."

  if [ -n "${SELECTED_VPS_REPORT:-}" ] && [ -r "${SELECTED_VPS_REPORT:-}" ]; then
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    return 0
  fi

  if [ "${WARREN_LUCI_REQUEST:-0}" = "1" ] || [ "$report_count" -eq 1 ]; then
    SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed '/^$/d' | head -n1)"
    [ -n "$SELECTED_VPS_REPORT" ] || fail "Не удалось выбрать VPS-отчёт для применения SNI"
    conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
    return 0
  fi

  say ""
  say "Выбери VPS, где нужно применить новый SNI:"
  report_index=1
  printf "%s\n" "$report_list" | while IFS= read -r report_file; do
    [ -n "$report_file" ] || continue
    say "$report_index) $(basename "$report_file" .txt)"
    report_index=$((report_index + 1))
  done
  ask "Выбор VPS" SNI_APPLY_REPORT_CHOICE "1"
  case "$SNI_APPLY_REPORT_CHOICE" in
    ''|*[!0-9]*) fail "Введи номер VPS-отчёта" ;;
  esac
  [ "$SNI_APPLY_REPORT_CHOICE" -ge 1 ] && [ "$SNI_APPLY_REPORT_CHOICE" -le "$report_count" ] || fail "Нет VPS-отчёта с номером $SNI_APPLY_REPORT_CHOICE"
  SELECTED_VPS_REPORT="$(printf "%s\n" "$report_list" | sed -n "${SNI_APPLY_REPORT_CHOICE}p")"
  conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
}

sni_apply_choose_new_sni() {
  latest_report="${SNI_REPORT_PATH:-}"
  [ -n "$latest_report" ] && [ -r "$latest_report" ] || latest_report="$(sni_apply_latest_txt_report)"
  best_sni=""
  [ -n "$latest_report" ] && best_sni="$(sni_apply_best_from_report "$latest_report" || true)"
  manual_sni="${SNI_NEW:-}"

  if [ -n "$manual_sni" ]; then
    NEW_SNI="$manual_sni"
  elif [ "${WARREN_LUCI_REQUEST:-0}" = "1" ] && [ "${SNI_APPLY_SOURCE:-best}" = "best" ] && [ -n "$best_sni" ]; then
    NEW_SNI="$best_sni"
  elif [ "${WARREN_LUCI_REQUEST:-0}" = "1" ]; then
    fail "В последнем SNI-отчёте нет GOOD-кандидата. Введи SNI вручную."
  else
    say ""
    if [ -n "$best_sni" ]; then
      say "Лучший GOOD из последнего отчёта: $best_sni"
    else
      say "В последнем отчёте нет GOOD-кандидата. Можно ввести SNI вручную."
    fi
    ask "Новый SNI" NEW_SNI "${best_sni:-}"
  fi

  [ -n "${NEW_SNI:-}" ] || fail "Новый SNI пустой"
  sni_apply_validate_domain "$NEW_SNI" || fail "Новый SNI не похож на домен: $NEW_SNI"

  SNI_REPORT_PATH="$latest_report"
  SNI_BEST_FROM_REPORT="$best_sni"
}

sni_apply_backup_state() {
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$(sni_checker_backups_dir)/sni-apply-$stamp"
  mkdir -p "$backup_dir" || fail "Не удалось создать backup-каталог $backup_dir"
  [ -r "$SELECTED_VPS_REPORT" ] && cp "$SELECTED_VPS_REPORT" "$backup_dir/vps-report.txt" 2>/dev/null || true
  printf "%s\n" "$OLD_VLESS_LINK" > "$backup_dir/old-vless.txt"
  uci show podkop > "$backup_dir/podkop-uci.txt" 2>/dev/null || true
  SNI_APPLY_BACKUP_DIR="$backup_dir"
}

sni_apply_update_vps_inbound() {
  login_3xui_api
  new_sni="$1"
  secondary_sni="$(sni_apply_secondary_name "$new_sni")"
  remote_script="/tmp/warren-sni-apply.py"
  remote_list="/tmp/warren-inbounds-list.json"
  remote_payload="/tmp/warren-inbound-update.json"
  remote_result="/tmp/warren-sni-apply.result"
  local_script="$(sni_checker_router_dir)/sni-apply.py"

  warren_install_payload sni-apply.py "$local_script"
  chmod 700 "$local_script" || fail "Не удалось подготовить локальный sni-apply.py"
  vps_write_remote_file "$local_script" "$remote_script" || fail "Не удалось загрузить SNI apply helper на VPS"
  inbound_arg="${INBOUND_ID:-_}"

  vps_ssh_timeout 90 "sh -lc '
    command -v python3 >/dev/null 2>&1 || { echo python3 is required on VPS for SNI apply; exit 7; }
    curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 30 -b $PANEL_COOKIE_REMOTE ${PANEL_API_BASE}/panel/api/inbounds/list > $remote_list
    python3 $remote_script $new_sni $secondary_sni $inbound_arg $remote_list $remote_payload > $remote_result
    update_id=\$(sed -n \"s/^INBOUND_ID=//p\" $remote_result | head -n1)
    [ -n \"\$update_id\" ] || exit 8
    curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 30 -b $PANEL_COOKIE_REMOTE -H \"Content-Type: application/json\" -X POST --data @$remote_payload ${PANEL_API_BASE}/panel/api/inbounds/update/\$update_id | grep -qi \"success\\|ok\\|true\"
    if command -v x-ui >/dev/null 2>&1; then x-ui restart >/dev/null 2>&1 || true; elif command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui >/dev/null 2>&1 || true; fi
    cat $remote_result
  '" || fail "Не удалось обновить Reality inbound через API 3x-ui"

  INBOUND_ID="$(vps_ssh_timeout 30 "sed -n 's/^INBOUND_ID=//p' $remote_result | head -n1" 2>/dev/null || true)"
  [ -n "$INBOUND_ID" ] && runtime_state_set "inbound_id" "$INBOUND_ID"
}

sni_apply_update_report() {
  report_file="$1"
  new_link="$2"
  tmp="${report_file}.tmp.$$"
  awk -v link="$new_link" '
    BEGIN { done=0 }
    /^VLESS inbound link: / { print "VLESS inbound link: " link; done=1; next }
    { print }
    END { if (!done) print "VLESS inbound link: " link }
  ' "$report_file" > "$tmp" || fail "Не удалось обновить VPS report"
  {
    printf "\nSNI apply updated at: %s\n" "$(date +'%F %T %z')"
    printf "SNI apply previous: %s\n" "$CURRENT_SNI"
    printf "SNI apply current: %s\n" "$NEW_SNI"
    printf "SNI apply backup: %s\n" "$SNI_APPLY_BACKUP_DIR"
  } >> "$tmp"
  mv "$tmp" "$report_file" || fail "Не удалось записать обновлённый VPS report"
  chmod 600 "$report_file" 2>/dev/null || true
}

sni_apply_update_endpoint_store() {
  endpoints="${WARREN_BASE_DIR:-/etc/warren}/warren-vless-endpoints"
  [ -f "$endpoints" ] || return 0
  tmp="${endpoints}.tmp.$$"
  awk -v old="$OLD_VLESS_LINK" -v new="$NEW_VLESS_LINK" '{ if ($0 == old) print new; else print }' "$endpoints" > "$tmp" || return 0
  mv "$tmp" "$endpoints" 2>/dev/null || true
  chmod 600 "$endpoints" 2>/dev/null || true
}

sni_apply_update_podkop() {
  if ! uciq get podkop.main >/dev/null; then
    warn "Podkop ещё не настроен. VPS report обновлён, новый VLESS: $NEW_VLESS_LINK"
    return 0
  fi
  mode="$(uci -q get podkop.main.proxy_config_type 2>/dev/null || true)"
  changed=0

  case "$mode" in
    url|"")
      current="$(uci -q get podkop.main.proxy_string 2>/dev/null || true)"
      if [ "$current" = "$OLD_VLESS_LINK" ]; then
        uciq set podkop.main.proxy_string="$NEW_VLESS_LINK"
        changed=1
      fi
      ;;
    urltest)
      links="$(uci -q get podkop.main.urltest_proxy_links 2>/dev/null | tr ' ' '\n')"
      uciq -q del podkop.main.urltest_proxy_links || true
      printf "%s\n" "$links" | sed '/^$/d' | while IFS= read -r link; do
        if [ "$link" = "$OLD_VLESS_LINK" ]; then
          uciq add_list podkop.main.urltest_proxy_links="$NEW_VLESS_LINK"
        else
          uciq add_list podkop.main.urltest_proxy_links="$link"
        fi
      done
      if printf "%s\n" "$links" | grep -Fxq "$OLD_VLESS_LINK"; then
        changed=1
      fi
      ;;
    *)
      warn "Podkop mode $mode пока не поддержан для автозамены SNI. VPS report обновлён, Podkop проверь вручную."
      return 0
      ;;
  esac

  if [ "$changed" = "1" ]; then
    uciq commit podkop
    /etc/init.d/podkop restart >/dev/null 2>&1 || warn "Podkop не подтвердил restart. Новый VLESS: $NEW_VLESS_LINK"
  else
    warn "Текущий Podkop endpoint не совпал со старой VLESS-ссылкой. Новый VLESS сохранён в report: $NEW_VLESS_LINK"
  fi
}

run_sni_apply_flow() {
  init_runtime_state
  runtime_state_set "mode" "sni_apply"
  sni_checker_ensure_router_layout
  load_conf_if_exists || true

  sni_apply_choose_report
  sni_apply_prepare_vps_context
  CURRENT_SNI="$(vps_report_vless_sni "$SELECTED_VPS_REPORT")"
  [ -n "$CURRENT_SNI" ] || CURRENT_SNI="unknown"
  OLD_VLESS_LINK="$VLESS_LINK"

  sni_apply_choose_new_sni
  current_status="$(sni_apply_current_status_from_report "$SNI_REPORT_PATH" "$CURRENT_SNI" || true)"
  [ -n "$current_status" ] || current_status="unknown"

  say ""
  say "Применение SNI"
  say "Текущий SNI: $CURRENT_SNI"
  say "Статус текущего SNI в последнем отчёте: $current_status"
  say "Новый SNI: $NEW_SNI"
  say "VPS report: $SELECTED_VPS_REPORT"
  say "SNI report: ${SNI_REPORT_PATH:-не найден}"
  say ""

  if [ "$CURRENT_SNI" = "$NEW_SNI" ]; then
    done_ "Новый SNI совпадает с текущим, менять нечего."
    return 0
  fi

  if [ "${WARREN_LUCI_REQUEST:-0}" != "1" ]; then
    ask "Применить новый SNI на VPS и роутере? (y/n)" SNI_APPLY_CONFIRM "n"
    case "$SNI_APPLY_CONFIRM" in
      y|Y) ;;
      *) done_ "Применение SNI отменено пользователем"; return 0 ;;
    esac
  fi

  sni_apply_backup_state
  sni_apply_update_vps_inbound "$NEW_SNI"
  NEW_VLESS_LINK="$(sni_apply_replace_vless_sni "$OLD_VLESS_LINK" "$NEW_SNI")"
  VLESS_LINK="$NEW_VLESS_LINK"
  VLESS="$NEW_VLESS_LINK"
  conf_set VLESS "$NEW_VLESS_LINK"
  conf_set SELECTED_VPS_REPORT "$SELECTED_VPS_REPORT"
  runtime_state_set "vless" "$NEW_VLESS_LINK"
  runtime_state_set "vless_link" "$NEW_VLESS_LINK"
  save_remote_artifact
  sni_apply_update_report "$SELECTED_VPS_REPORT" "$NEW_VLESS_LINK"
  sni_apply_update_endpoint_store
  sni_apply_update_podkop

  done_ "SNI применён: $CURRENT_SNI -> $NEW_SNI. Backup: $SNI_APPLY_BACKUP_DIR"
}
