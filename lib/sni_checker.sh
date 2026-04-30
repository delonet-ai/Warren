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

sni_checker_ensure_router_layout() {
  mkdir -p "$(sni_checker_router_dir)" "$(sni_checker_router_reports_dir)" || fail "Не удалось создать каталог SNI-checker на роутере"
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
  cat > "$local_script" <<'EOF'
#!/usr/bin/env bash
set -u
set -o pipefail

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CANDIDATES_FILE="${1:-$BASE_DIR/sni-candidates.txt}"
CURRENT_SNI="${2:-vk.ru}"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$BASE_DIR/report-$STAMP.csv"
TXT="$BASE_DIR/report-$STAMP.txt"
TMP_DIR="$BASE_DIR/.tmp-$STAMP"
mkdir -p "$BASE_DIR" "$TMP_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf "%s\n" "$*" | tee -a "$TXT"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

missing_tools=()
for tool in bash openssl curl timeout ss; do
  need_cmd "$tool" || missing_tools+=("$tool")
done
if ! need_cmd getent && ! need_cmd dig; then
  missing_tools+=("getent|dig")
fi

if [ "${#missing_tools[@]}" -gt 0 ]; then
  printf "Missing tools on VPS: %s\n" "${missing_tools[*]}"
  printf "Install on Ubuntu/Debian: apt-get update && apt-get install -y bash curl openssl coreutils iproute2 libc-bin dnsutils procps iptables nftables\n"
  exit 2
fi

if [ ! -r "$CANDIDATES_FILE" ]; then
  printf "Candidates file not found: %s\n" "$CANDIDATES_FILE"
  exit 2
fi

safe_firewall_snapshot() {
  if command -v ufw >/dev/null 2>&1; then
    ufw status || true
    return 0
  fi
  if command -v nft >/dev/null 2>&1; then
    nft list ruleset || true
    return 0
  fi
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save || true
    return 0
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -S || true
    return 0
  fi
  echo "No ufw/nftables/iptables tool found"
}

public_ip() {
  curl -4fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null \
    || curl -4fsS --connect-timeout 5 --max-time 8 https://ifconfig.me 2>/dev/null \
    || echo "unknown"
}

dns_lookup() {
  local domain="$1"
  local ip=""
  if need_cmd getent; then
    ip="$(getent ahosts "$domain" 2>/dev/null | awk '/STREAM/ {print $1; exit}')"
    [ -n "$ip" ] || ip="$(getent hosts "$domain" 2>/dev/null | awk 'NR==1 {print $1}')"
  fi
  if [ -z "$ip" ] && need_cmd dig; then
    ip="$(dig +short A "$domain" 2>/dev/null | head -n1)"
    [ -n "$ip" ] || ip="$(dig +short AAAA "$domain" 2>/dev/null | head -n1)"
  fi
  printf "%s" "$ip"
}

tcp_443_check() {
  local domain="$1"
  timeout 5 bash -lc "exec 3<>/dev/tcp/${domain}/443" >/dev/null 2>&1
}

http_probe() {
  local domain="$1"
  local port="$2"
  local scheme="$3"
  local extra_flag="$4"
  local out_file="$5"
  local url="${scheme}://${domain}:${port}/"
  curl $extra_flag -vIs --connect-timeout 5 --max-time 10 "$url" >"$out_file" 2>&1
}

tcp_port_check() {
  local domain="$1"
  local port="$2"
  local out_file="$TMP_DIR/probe-${domain//[^A-Za-z0-9._-]/_}-${port}.log"

  if [ "$port" = "443" ]; then
    if http_probe "$domain" "$port" "https" "-k" "$out_file"; then
      return 0
    fi
  else
    if http_probe "$domain" "$port" "http" "" "$out_file"; then
      return 0
    fi
  fi

  grep -Eqi 'Connected to|Received HTTP/0\.9|Empty reply from server|invalid SSL record|wrong version number|first record does not look like a TLS handshake' "$out_file"
}

bool_mark() {
  [ "$1" = "yes" ] && printf "yes" || printf "no"
}

rank_value() {
  case "$1" in
    GOOD) printf "3" ;;
    CHECK) printf "2" ;;
    BAD) printf "1" ;;
    *) printf "0" ;;
  esac
}

secondary_name() {
  local domain="$1"
  case "$domain" in
    www.*) printf "%s" "$domain" ;;
    *) printf "www.%s" "$domain" ;;
  esac
}

printf "domain,status,ip,dns_ok,tcp443_ok,tls13_ok,verify_ok,alpn_h2,curl_ok,http_code,http_version,time_total_s,note\n" >"$CSV"
: >"$TXT"
: >"$TMP_DIR/ranks.tsv"

log "Warren SNI checker"
log "=================="
log ""
log "Safety: read-only checks only. No 3x-ui restart, no config edits, no firewall changes."
log ""
log "hostname: $(hostname)"
if [ -r /etc/os-release ]; then
  log "os: $(. /etc/os-release 2>/dev/null; printf "%s" "${PRETTY_NAME:-unknown}")"
else
  log "os: unknown"
fi
log "public_ip: $(public_ip)"
log ""
log "Listening ports (ss -tulpn):"
ss -tulpn 2>&1 | tee -a "$TXT"
log ""
log "Firewall snapshot:"
safe_firewall_snapshot 2>&1 | tee -a "$TXT"
log ""
log "Candidates file: $CANDIDATES_FILE"
log "Current SNI: $CURRENT_SNI"
log ""

printf "%-24s %-6s %-3s %-3s %-4s %-3s %-3s %-5s %-7s %s\n" "domain" "status" "dns" "tcp" "tls" "ver" "h2" "http2" "time" "note" | tee -a "$TXT"
printf "%-24s %-6s %-3s %-3s %-4s %-3s %-3s %-5s %-7s %s\n" "------------------------" "------" "---" "---" "----" "---" "---" "-----" "-------" "----" | tee -a "$TXT"

while IFS= read -r domain; do
  domain="${domain%%#*}"
  domain="$(printf "%s" "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$domain" ] || continue

  dns_ok="no"
  tcp_ok="no"
  tls_ok="no"
  verify_ok="no"
  h2_ok="no"
  curl_ok="no"
  http_code="-"
  http_version="-"
  time_total="-"
  note=""
  status="BAD"
  ip_addr="$(dns_lookup "$domain")"

  if [ -z "$ip_addr" ]; then
    note="DNS fail"
  else
    dns_ok="yes"
  fi

  if [ "$dns_ok" = "yes" ] && tcp_443_check "$domain"; then
    tcp_ok="yes"
  elif [ "$dns_ok" = "yes" ]; then
    note="${note:+$note; }TCP 443 fail"
  fi

  tls_log="$TMP_DIR/tls-${domain//[^A-Za-z0-9._-]/_}.log"
  if [ "$tcp_ok" = "yes" ]; then
    if timeout 12 openssl s_client -connect "${domain}:443" -servername "$domain" -alpn h2 -tls1_3 </dev/null >"$tls_log" 2>&1; then
      :
    fi

    if grep -Eq 'TLSv1\.3|Protocol *: TLSv1\.3' "$tls_log"; then
      tls_ok="yes"
    else
      note="${note:+$note; }TLS 1.3 fail"
    fi

    if grep -q 'Verify return code: 0 (ok)' "$tls_log"; then
      verify_ok="yes"
    else
      note="${note:+$note; }verify fail"
    fi

    if grep -q 'ALPN protocol: h2' "$tls_log"; then
      h2_ok="yes"
    else
      note="${note:+$note; }no h2 ALPN"
    fi
  fi

  curl_meta="$TMP_DIR/curl-${domain//[^A-Za-z0-9._-]/_}.meta"
  curl_err="$TMP_DIR/curl-${domain//[^A-Za-z0-9._-]/_}.err"
  if [ "$tcp_ok" = "yes" ]; then
    if curl -I --http2 -sS --connect-timeout 8 --max-time 15 -o /dev/null -w '%{time_total} %{http_code} %{http_version}\n' "https://${domain}/" >"$curl_meta" 2>"$curl_err"; then
      curl_ok="yes"
      read -r time_total http_code http_version <"$curl_meta"
    else
      if [ -s "$curl_meta" ]; then
        read -r time_total http_code http_version <"$curl_meta"
      fi
      note="${note:+$note; }curl fail"
    fi
  fi

  if [ "$dns_ok" = "yes" ] && [ "$tcp_ok" = "yes" ] && [ "$tls_ok" = "yes" ] && [ "$verify_ok" = "yes" ] && [ "$h2_ok" = "yes" ] && [ "$curl_ok" = "yes" ]; then
    if awk "BEGIN {exit !($time_total <= 2.50)}" 2>/dev/null; then
      status="GOOD"
    else
      status="CHECK"
      note="${note:+$note; }slow"
    fi
  elif [ "$dns_ok" = "yes" ] && [ "$tcp_ok" = "yes" ] && [ "$tls_ok" = "yes" ]; then
    status="CHECK"
  else
    status="BAD"
  fi

  [ -n "$note" ] || note="ok"
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$domain" "$status" "${ip_addr:-}" "$dns_ok" "$tcp_ok" "$tls_ok" "$verify_ok" "$h2_ok" "$curl_ok" "$http_code" "$http_version" "$time_total" "$note" >>"$CSV"
  printf "%s\t%s\t%s\n" "$(rank_value "$status")" "${time_total:--}" "$domain" >>"$TMP_DIR/ranks.tsv"
  printf "%-24.24s %-6s %-3s %-3s %-4s %-3s %-3s %-5s %-7s %s\n" \
    "$domain" "$status" "$(bool_mark "$dns_ok")" "$(bool_mark "$tcp_ok")" "$(bool_mark "$tls_ok")" "$(bool_mark "$verify_ok")" "$(bool_mark "$h2_ok")" "$(printf "%s" "$http_version" | grep -q '^2' && echo yes || echo no)" "$time_total" "$note" | tee -a "$TXT"
done <"$CANDIDATES_FILE"

log ""
log "Recommendations"
log "---------------"

best_domain="$(sort -t $'\t' -k1,1nr -k2,2n "$TMP_DIR/ranks.tsv" | awk -F'\t' '$1 >= 2 {print $3; exit}')"
if [ -n "$best_domain" ]; then
  log "Top 5:"
  sort -t $'\t' -k1,1nr -k2,2n "$TMP_DIR/ranks.tsv" | awk -F'\t' '$1 >= 2 {print "- " $3}' | head -n5 | tee -a "$TXT"
else
  log "Top 5: no GOOD/CHECK candidates"
fi

bad_domains="$(awk -F, 'NR>1 && $2=="BAD" {print $1}' "$CSV")"
if [ -n "$bad_domains" ]; then
  log ""
  log "Exclude:"
  printf "%s\n" "$bad_domains" | sed 's/^/- /' | tee -a "$TXT"
fi

log ""
current_line="$(awk -F, -v want="$CURRENT_SNI" 'NR>1 && $1==want {print $0; exit}' "$CSV")"
best_line="$(awk -F, -v want="$best_domain" 'NR>1 && $1==want {print $0; exit}' "$CSV")"

if [ -n "$current_line" ]; then
  current_status="$(printf "%s" "$current_line" | awk -F, '{print $2}')"
  current_time="$(printf "%s" "$current_line" | awk -F, '{print $12}')"
  log "Current SNI: $CURRENT_SNI ($current_status, time=${current_time:-n/a}s)"
else
  log "Current SNI: $CURRENT_SNI (not present in candidates file)"
fi

if [ -n "$best_line" ]; then
  best_status="$(printf "%s" "$best_line" | awk -F, '{print $2}')"
  best_time="$(printf "%s" "$best_line" | awk -F, '{print $12}')"
  log "Best candidate: $best_domain ($best_status, time=${best_time:-n/a}s)"
  log ""
  log "Recommended 3x-ui Reality params:"
  log "- dest: ${best_domain}:443"
  log "- serverNames: ${best_domain}"
  log "- client sni: ${best_domain}"
  log "- optional second serverName: $(secondary_name "$best_domain")"
else
  log "No suitable SNI candidate found."
fi

log ""
log "__WARREN_REPORT_CSV__ $CSV"
log "__WARREN_REPORT_TXT__ $TXT"
EOF
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
  ask "Загрузить и запустить SNI-checker на VPS? (y/n)" SNI_CHECKER_CONFIRM "y"
  case "$SNI_CHECKER_CONFIRM" in
    y|Y) ;;
    n|N) done_ "SNI-checker подготовлен, запуск отменён пользователем"; return 0 ;;
    *) fail "Введи y или n" ;;
  esac

  sni_checker_upload_files
  sni_checker_run_remote
}
