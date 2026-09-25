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
