# 3x-ui on the VPS: packages, install, admin/API access, Warren remote artifacts.

json_get_string() {
  key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

json_has_success_true() {
  grep -q '"success"[[:space:]]*:[[:space:]]*true'
}

json_get_number() {
  key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n1
}

json_get_first_string() {
  for key in "$@"; do
    value="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1)"
    [ -n "$value" ] && {
      printf "%s\n" "$value"
      return 0
    }
  done
  return 1
}

vps_remote_state_dir() {
  printf "%s" "/root/.warren"
}

vps_remote_artifact_file() {
  printf "%s/3xui.env" "$(vps_remote_state_dir)"
}

vps_local_artifact_cache() {
  printf "%s/%s.env" "$(vps_workspace_dir)" "$(vps_sanitized_host)"
}

is_3xui_installed() {
  vps_ssh "test -x /usr/local/x-ui/x-ui"
}

upgrade_vps_packages() {
  case "$VPS_OS_ID" in
    ubuntu|debian|raspbian|armbian)
      vps_ssh_timeout 1800 "sh -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y && apt-get install -y bash curl ca-certificates coreutils procps openssl dnsutils iproute2'" \
        || fail "Не удалось обновить пакеты на VPS (apt)"
      ;;
    centos|rhel|almalinux|rocky|fedora|ol)
      vps_ssh "sh -lc 'if command -v dnf >/dev/null 2>&1; then dnf upgrade -y && dnf install -y curl ca-certificates; else yum update -y && yum install -y curl ca-certificates; fi'" \
        || fail "Не удалось обновить пакеты на VPS (dnf/yum)"
      ;;
    arch|manjaro|parch)
      vps_ssh "sh -lc 'pacman -Syu --noconfirm curl ca-certificates'" \
        || fail "Не удалось обновить пакеты на VPS (pacman)"
      ;;
    opensuse*|sles)
      vps_ssh "sh -lc 'zypper refresh && zypper update -y && zypper install -y curl ca-certificates'" \
        || fail "Не удалось обновить пакеты на VPS (zypper)"
      ;;
    alpine)
      vps_ssh "sh -lc 'apk update && apk upgrade && apk add curl ca-certificates'" \
        || fail "Не удалось обновить пакеты на VPS (apk)"
      ;;
    *)
      fail "Пока не поддерживается автоматический апгрейд пакетов для ОС: ${VPS_OS_ID:-unknown}"
      ;;
  esac

  vps_step_done "ОС определена: ${VPS_OS_PRETTY:-unknown}; штатный апгрейд пакетов выполнен"
}

install_3xui() {
  info "Установка 3x-ui может занять некоторое время. Процесс идёт, пожалуйста подождите..."
  xui_release_tag="${WARREN_3XUI_RELEASE_TAG:-${WARREN_3XUI_PINNED_RELEASE_TAG:-v3.5.0}}"
  xui_installer_sha="${WARREN_3XUI_INSTALL_SHA256:-}"
  [ -n "$xui_installer_sha" ] || fail "Для 3x-ui installer не задан ожидаемый SHA256"
  vps_ssh_timeout 1200 "sh -lc '
    log=/tmp/warren-3xui-install.log
    rcfile=/tmp/warren-3xui-install.rc
    installer=/tmp/warren-3xui-install.sh
    rm -f \"\$log\" \"\$rcfile\" \"\$installer\"

    echo \"__WARREN_STEP__ download installer ${xui_release_tag}\" >\"\$log\"
    curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/${xui_release_tag}/install.sh -o \"\$installer\" >>\"\$log\" 2>&1
    actual_sha=\"\$(sha256sum \"\$installer\" 2>/dev/null | awk \"{print \\\$1}\")\"
    if [ \"\$actual_sha\" != \"${xui_installer_sha}\" ]; then
      echo \"Warren: 3x-ui installer SHA256 mismatch: expected ${xui_installer_sha}, got \${actual_sha:-unknown}\" >>\"\$log\"
      exit 65
    fi
    echo \"__WARREN_STEP__ installer SHA256 verified\" >>\"\$log\"
    chmod +x \"\$installer\"

    (
      echo \"__WARREN_STEP__ run installer\"
      export DEBIAN_FRONTEND=noninteractive
      if command -v timeout >/dev/null 2>&1; then
        timeout 900 bash \"\$installer\" \"${xui_release_tag}\" < /dev/null
        install_rc=\$?
      else
        bash \"\$installer\" \"${xui_release_tag}\" < /dev/null
        install_rc=\$?
      fi
      echo \"\$install_rc\" > \"\$rcfile\"
      echo \"__WARREN_INSTALL_RC__ \$install_rc\"
    ) >>\"\$log\" 2>&1 &
    installer_pid=\$!

    elapsed=0
    ready=0
    ready_since=-1
    while [ \"\$elapsed\" -lt 900 ]; do
      if [ -f \"\$rcfile\" ]; then
        break
      fi

      if [ -x /usr/local/x-ui/x-ui ]; then
        if command -v systemctl >/dev/null 2>&1; then
          if [ -f /etc/systemd/system/x-ui.service ] && systemctl is-active --quiet x-ui >/dev/null 2>&1; then
            if [ \"\$ready\" = \"0\" ]; then
              ready=1
              ready_since=\$elapsed
              echo \"Warren: 3x-ui service is ready; waiting up to 120s for installer cleanup\" >>\"\$log\"
            fi
          fi
        elif pgrep -f /usr/local/x-ui/x-ui >/dev/null 2>&1; then
          if [ \"\$ready\" = \"0\" ]; then
            ready=1
            ready_since=\$elapsed
          fi
        fi
      fi

      if [ \"\$ready\" = \"1\" ] && [ \$((elapsed - ready_since)) -ge 120 ]; then
        break
      fi

      sleep 2
      elapsed=\$((elapsed + 2))
    done

    if [ \"\$ready\" = \"1\" ] && [ ! -f \"\$rcfile\" ]; then
      echo \"Warren: installer did not exit 120s after service became ready; stopping pid \$installer_pid\" >>\"\$log\"
      pkill -P \"\$installer_pid\" >/dev/null 2>&1 || true
      kill \"\$installer_pid\" >/dev/null 2>&1 || true
      sleep 1
      pkill -9 -P \"\$installer_pid\" >/dev/null 2>&1 || true
      kill -9 \"\$installer_pid\" >/dev/null 2>&1 || true
    fi

    tail -n 180 \"\$log\" 2>/dev/null || true

    if [ -f \"\$rcfile\" ]; then
      install_rc=\"\$(cat \"\$rcfile\" 2>/dev/null || echo 1)\"
      case \"\$install_rc\" in
        0) ;;
        124|137|143)
          [ \"\$ready\" = \"1\" ] || {
            echo \"Warren: 3x-ui installer stopped with rc=\$install_rc before service became ready\"
            exit \"\$install_rc\"
          }
          echo \"Warren: accepting installer rc=\$install_rc because 3x-ui service is ready\" >>\"\$log\"
          ;;
        *)
          echo \"Warren: 3x-ui installer failed with rc=\$install_rc\"
          exit \"\$install_rc\"
          ;;
      esac
    elif [ \"\$ready\" != \"1\" ]; then
      echo \"Warren: 3x-ui installer timed out before service became ready\"
      exit 124
    fi

    test -x /usr/local/x-ui/x-ui || exit 1
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable x-ui >/dev/null 2>&1 || true
      systemctl restart x-ui >/dev/null 2>&1 || systemctl restart x-ui.service >/dev/null 2>&1 || exit 1
      i=0
      while [ \"\$i\" -lt 30 ]; do
        systemctl is-active --quiet x-ui >/dev/null 2>&1 && exit 0
        sleep 1
        i=\$((i + 1))
      done
      systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,80p\" || true
      exit 1
    fi

    pgrep -f /usr/local/x-ui/x-ui >/dev/null 2>&1 || exit 1
    exit 0
  '" \
    || {
      vps_ssh_timeout 60 "sh -lc 'echo __WARREN_3XUI_INSTALL_LOG__; tail -n 220 /tmp/warren-3xui-install.log 2>/dev/null || true; echo __WARREN_3XUI_STATUS__; systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,100p\" || true; echo __WARREN_3XUI_FILES__; ls -la /usr/local/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service 2>/dev/null || true'" || true
      fail "Не удалось установить 3x-ui на VPS"
    }
  vps_step_done "3x-ui установлен"
}

configure_3xui_admin() {
  PANEL_USERNAME="warren$(random_token 6)"
  PANEL_PASSWORD="$(random_token 18)"

  info "Настраиваю логин и пароль 3x-ui..."
  vps_ssh_timeout 120 "sh -lc '
    if command -v timeout >/dev/null 2>&1; then
      timeout 45 /usr/local/x-ui/x-ui setting -username $(quote_sh "$PANEL_USERNAME") -password $(quote_sh "$PANEL_PASSWORD") -resetTwoFactor true >/tmp/warren-3xui-setting.log 2>&1
    else
      /usr/local/x-ui/x-ui setting -username $(quote_sh "$PANEL_USERNAME") -password $(quote_sh "$PANEL_PASSWORD") -resetTwoFactor true >/tmp/warren-3xui-setting.log 2>&1
    fi
  '" \
    || {
      vps_ssh_timeout 60 "sh -lc 'echo __WARREN_3XUI_SETTING_LOG__; cat /tmp/warren-3xui-setting.log 2>/dev/null || true; echo __WARREN_3XUI_STATUS__; systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,80p\" || true'" || true
      fail "Не удалось настроить логин и пароль 3x-ui"
    }

  info "Перезапускаю 3x-ui через systemd..."
  vps_ssh_timeout 120 "sh -lc '
    if command -v systemctl >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 45 systemctl restart x-ui && exit 0
        timeout 45 systemctl restart x-ui.service && exit 0
      else
        systemctl restart x-ui && exit 0
        systemctl restart x-ui.service && exit 0
      fi
    fi
    if command -v service >/dev/null 2>&1; then
      service x-ui restart && exit 0
    fi
    if command -v timeout >/dev/null 2>&1 && command -v x-ui >/dev/null 2>&1; then
      timeout 20 x-ui restart </dev/null >/dev/null 2>&1 && exit 0
    fi
    exit 1
  '" \
    || {
      vps_ssh_timeout 60 "sh -lc 'echo __WARREN_3XUI_STATUS__; systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,100p\" || service x-ui status 2>/dev/null || true; echo __WARREN_3XUI_JOURNAL__; journalctl -u x-ui --no-pager -n 80 2>/dev/null || true'" || true
      fail "Не удалось перезапустить 3x-ui после настройки учётных данных"
    }

  info "Проверяю, что 3x-ui active..."
  vps_ssh_timeout 90 "sh -lc '
    if command -v systemctl >/dev/null 2>&1; then
      i=0
      while [ \"\$i\" -lt 30 ]; do
        systemctl is-active --quiet x-ui >/dev/null 2>&1 && exit 0
        sleep 1
        i=\$((i + 1))
      done
      systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,80p\" || true
      exit 1
    fi
    pgrep -f /usr/local/x-ui/x-ui >/dev/null 2>&1
  '" || fail "3x-ui не стал active после перезапуска"
}

normalize_panel_base_path() {
  raw_base="$(printf "%s" "${1:-}" | sed 's/[[:space:]]//g')"
  case "$raw_base" in
    ""|"/") printf "" ;;
    /*/) printf "%s" "${raw_base%/}" ;;
    /*) printf "%s" "$raw_base" ;;
    */) printf "/%s" "${raw_base%/}" ;;
    *) printf "/%s" "$raw_base" ;;
  esac
}

refresh_3xui_panel_settings() {
  fresh_panel_info="$(vps_ssh_timeout 30 "sh -lc '/usr/local/x-ui/x-ui setting -show 2>/dev/null || true'")" || return 1
  fresh_panel_port="$(printf "%s\n" "$fresh_panel_info" | sed -n 's/.*[Pp]ort: *\([0-9][0-9]*\).*/\1/p' | head -n1)"
  fresh_panel_base="$(printf "%s\n" "$fresh_panel_info" | sed -n 's/.*webBasePath: \(.*\)$/\1/p' | head -n1)"
  case "$fresh_panel_info" in
    *"not secure with SSL"*) PANEL_HTTP_FIRST="1" ;;
    *) PANEL_HTTP_FIRST="${PANEL_HTTP_FIRST:-0}" ;;
  esac
  [ -n "$fresh_panel_port" ] && PANEL_PORT="$fresh_panel_port"
  PANEL_BASE_PATH="$(normalize_panel_base_path "$fresh_panel_base")"
  runtime_state_set "panel_port" "$PANEL_PORT"
  runtime_state_set "panel_base_path" "$PANEL_BASE_PATH"
}

wait_for_3xui_panel() {
  PANEL_SCHEME=""

  refresh_3xui_panel_settings || true

  i=1
  while [ "$i" -le 30 ]; do
    [ "$i" -eq 1 ] || [ $((i % 5)) -ne 0 ] || refresh_3xui_panel_settings || true
    base="${PANEL_BASE_PATH:-}"
    case "$base" in
      "") panel_paths="/login /" ;;
      /) panel_paths="/login /" ;;
      *)
        panel_paths="$base/login $base ${base}/ /login /"
        ;;
    esac

    for panel_path in $panel_paths; do
      if [ "${PANEL_HTTP_FIRST:-0}" = "1" ]; then
        if vps_ssh_timeout 12 "sh -lc 'code=\"\$(curl -sS -o /dev/null -w \"%{http_code}\" --connect-timeout 2 --max-time 4 http://127.0.0.1:${PANEL_PORT}${panel_path} 2>/dev/null || true)\"; case \"\$code\" in 2*|3*) exit 0 ;; *) exit 1 ;; esac'"; then
          PANEL_SCHEME="http"
          PANEL_HEALTH_PATH="$panel_path"
          return 0
        fi
      fi
      if vps_ssh_timeout 12 "sh -lc 'code=\"\$(curl -ksS -o /dev/null -w \"%{http_code}\" --connect-timeout 2 --max-time 4 https://127.0.0.1:${PANEL_PORT}${panel_path} 2>/dev/null || true)\"; case \"\$code\" in 2*|3*) exit 0 ;; *) exit 1 ;; esac'"; then
        PANEL_SCHEME="https"
        PANEL_HEALTH_PATH="$panel_path"
        return 0
      fi
      if [ "${PANEL_HTTP_FIRST:-0}" != "1" ] && vps_ssh_timeout 12 "sh -lc 'code=\"\$(curl -sS -o /dev/null -w \"%{http_code}\" --connect-timeout 2 --max-time 4 http://127.0.0.1:${PANEL_PORT}${panel_path} 2>/dev/null || true)\"; case \"\$code\" in 2*|3*) exit 0 ;; *) exit 1 ;; esac'"; then
        PANEL_SCHEME="http"
        PANEL_HEALTH_PATH="$panel_path"
        return 0
      fi
    done
    sleep 3
    i=$((i + 1))
  done
  say ""
  warn "3x-ui не ответил на локальную проверку панели. Ниже диагностика с VPS."
  vps_ssh_timeout 60 "sh -lc '
    echo __XUI_SETTING__;
    /usr/local/x-ui/x-ui setting -show 2>&1 || true;
    echo __LISTEN__;
    ss -lntup 2>/dev/null | grep -E \"x-ui|:${PANEL_PORT}[[:space:]]\" || ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true;
    echo __SERVICE__;
    systemctl status x-ui --no-pager -l 2>/dev/null | sed -n \"1,80p\" || service x-ui status 2>/dev/null || true;
  '" || true
  fail "3x-ui не поднялся на локальном URL панели: https://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
}

collect_3xui_access_info() {
  panel_info="$(vps_ssh_timeout 60 "sh -lc '/usr/local/x-ui/x-ui setting -show 2>/dev/null || true'")"
  PANEL_PORT="$(printf "%s\n" "$panel_info" | sed -n 's/.*[Pp]ort: *\([0-9][0-9]*\).*/\1/p' | head -n1)"
  PANEL_BASE_PATH="$(printf "%s\n" "$panel_info" | sed -n 's/.*webBasePath: \(.*\)$/\1/p' | head -n1)"
  [ -n "$PANEL_PORT" ] || fail "Не удалось определить порт панели 3x-ui через setting -show"
  PANEL_BASE_PATH="$(normalize_panel_base_path "$PANEL_BASE_PATH")"

  runtime_state_set "panel_username" "$PANEL_USERNAME"
  runtime_state_set "panel_password" "$PANEL_PASSWORD"
  runtime_state_set "panel_port" "$PANEL_PORT"
  runtime_state_set "panel_base_path" "$PANEL_BASE_PATH"

  wait_for_3xui_panel
  [ -n "${PANEL_SCHEME:-}" ] || PANEL_SCHEME="https"
  PANEL_URL="${PANEL_SCHEME}://${VPS_HOST}:${PANEL_PORT}${PANEL_BASE_PATH}"
  runtime_state_set "panel_scheme" "$PANEL_SCHEME"
  runtime_state_set "panel_url" "$PANEL_URL"
}

collect_3xui_api_token() {
  PANEL_API_TOKEN=""
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    api_token_info="$(vps_ssh_timeout 20 "sh -lc '
      if [ -r /etc/x-ui/install-result.env ]; then
        . /etc/x-ui/install-result.env
        printf \"%s\" \"\${XUI_API_TOKEN:-}\"
      else
        sqlite3 /etc/x-ui/x-ui.db \"select token from api_tokens where enabled=1 order by id desc limit 1;\" 2>/dev/null || true
      fi
    '")"
    PANEL_API_TOKEN="$(printf "%s\n" "$api_token_info" | head -n1 | tr -d ' \t\n\r')"
    if [ -z "$PANEL_API_TOKEN" ]; then
      api_token_info="$(vps_ssh_timeout 20 "sh -lc '/usr/local/x-ui/x-ui settings 2>/dev/null || true'")"
      PANEL_API_TOKEN="$(printf "%s\n" "$api_token_info" | sed -n 's/.*apiToken: *//p' | head -n1 | tr -d ' \t\n\r')"
    fi
    [ -n "$PANEL_API_TOKEN" ] && break
    attempt=$((attempt + 1))
    sleep 1
  done
  [ -n "$PANEL_API_TOKEN" ] || return 1
  runtime_state_set "panel_api_token" "$PANEL_API_TOKEN"
}

# Prefer the plaintext token emitted once by modern 3x-ui installers. Newer
# releases store only SHA256(token) in SQLite, so a DB value must never be
# inserted or reused as though it were the bearer secret.
ensure_3xui_api_token() {
  collect_3xui_api_token
}

login_3xui_api() {
  login_json_remote="/tmp/warren-panel-login.json"
  PANEL_COOKIE_REMOTE="/tmp/warren-panel.cookie"
  login_script_local="$(vps_workspace_dir)/panel-login-attempt.sh"
  login_script_remote="/tmp/warren-panel-login-attempt.sh"
  PANEL_CSRF_TOKEN=""

  panel_scheme="${PANEL_SCHEME:-https}"
  curl_tls_flag=""
  [ "$panel_scheme" = "https" ] && curl_tls_flag="-k"
  PANEL_CURL_FLAGS="$curl_tls_flag --http1.1"
  PANEL_API_BASE="${panel_scheme}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
  PANEL_BASE_URL="${panel_scheme}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}/"

  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    printf 'PANEL_USERNAME=%s\n' "$(quote_sh "$PANEL_USERNAME")"
    printf 'PANEL_PASSWORD=%s\n' "$(quote_sh "$PANEL_PASSWORD")"
    printf 'PANEL_CURL_FLAGS=%s\n' "$(quote_sh "$PANEL_CURL_FLAGS")"
    printf 'PANEL_API_BASE=%s\n' "$(quote_sh "$PANEL_API_BASE")"
    printf 'PANEL_BASE_URL=%s\n' "$(quote_sh "$PANEL_BASE_URL")"
    printf 'PANEL_COOKIE_REMOTE=%s\n' "$(quote_sh "$PANEL_COOKIE_REMOTE")"
    printf 'PANEL_LOGIN_REMOTE=%s\n' "$(quote_sh "$login_json_remote")"
    printf 'PANEL_CSRF_TOKEN=%s\n' "$(quote_sh "$PANEL_CSRF_TOKEN")"
    printf 'page="$(curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 20 -c "$PANEL_COOKIE_REMOTE" -b "$PANEL_COOKIE_REMOTE" "$PANEL_BASE_URL" 2>/dev/null || true)"\n'
    printf 'PANEL_CSRF_TOKEN="$(printf "%%s" "$page" | sed -n '\''s/.*meta name="csrf-token" content="\\([^"]*\\)".*/\\1/p'\'' | head -n1)"\n'
    printf 'if [ -z "$PANEL_CSRF_TOKEN" ]; then\n'
    printf '  PANEL_CSRF_TOKEN="$(printf "%%s" "$page" | sed -n '\''s/.*csrf-token.*content="\\([^"]*\\)".*/\\1/p'\'' | head -n1)"\n'
    printf 'fi\n'
    printf 'login_try() {\n'
    printf '  endpoint="$1"\n'
    printf '  mode="$2"\n'
    printf '  case "$mode" in\n'
    printf '    json)\n'
    printf '      cat > "$PANEL_LOGIN_REMOTE" <<EOFJSON\n'
    printf '{"username":"%s","password":"%s","twoFactorCode":""}\n' "$(json_escape "$PANEL_USERNAME")" "$(json_escape "$PANEL_PASSWORD")"
    printf 'EOFJSON\n'
    printf '      resp="$(curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 20 -c "$PANEL_COOKIE_REMOTE" -b "$PANEL_COOKIE_REMOTE" -H "Content-Type: application/json" -H "Accept: application/json, text/plain, */*" -H "X-Requested-With: XMLHttpRequest" -H "Origin: %s" -H "Referer: %s" ${PANEL_CSRF_TOKEN:+-H "X-CSRF-Token: $PANEL_CSRF_TOKEN"} --data @"$PANEL_LOGIN_REMOTE" "$endpoint" 2>/dev/null || true)"\n' "$panel_scheme://127.0.0.1:${PANEL_PORT}" "$PANEL_BASE_URL"
    printf '      ;;\n'
    printf '    form)\n'
    printf '      resp="$(curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 20 -c "$PANEL_COOKIE_REMOTE" -b "$PANEL_COOKIE_REMOTE" -H "Accept: application/json, text/plain, */*" -H "X-Requested-With: XMLHttpRequest" -H "Origin: %s" -H "Referer: %s" ${PANEL_CSRF_TOKEN:+-H "X-CSRF-Token: $PANEL_CSRF_TOKEN"} -F "username=$PANEL_USERNAME" -F "password=$PANEL_PASSWORD" -F "twoFactorCode=" "$endpoint" 2>/dev/null || true)"\n' "$panel_scheme://127.0.0.1:${PANEL_PORT}" "$PANEL_BASE_URL"
    printf '      ;;\n'
    printf '    *) return 1 ;;\n'
    printf '  esac\n'
    printf '  printf "%%s" "$resp" | grep -qi "success\\|ok\\|true" && return 0\n'
    printf '  return 1\n'
    printf '}\n'
    printf 'for endpoint in "$PANEL_API_BASE/login" "$PANEL_API_BASE/login/"; do\n'
    printf '  for mode in json form; do\n'
    printf '    if login_try "$endpoint" "$mode"; then\n'
    printf '      printf "LOGIN_ENDPOINT=%%s\\n" "$endpoint"\n'
    printf '      printf "LOGIN_MODE=%%s\\n" "$mode"\n'
    printf '      exit 0\n'
    printf '    fi\n'
    printf '  done\n'
    printf 'done\n'
    printf 'exit 1\n'
  } > "$login_script_local" || fail "Не удалось подготовить login retry script для 3x-ui"
  chmod 700 "$login_script_local" 2>/dev/null || true

  vps_write_remote_file "$login_script_local" "$login_script_remote" || fail "Не удалось загрузить login retry script на VPS"

  login_resp="$(vps_ssh_timeout 60 "sh $(quote_sh "$login_script_remote")")" || return 1

  printf "%s" "$login_resp" | grep -qi "LOGIN_ENDPOINT=\|LOGIN_MODE=\|success\|ok\|true" || return 1
  collect_3xui_api_token || warn "Не удалось получить API token 3x-ui, буду использовать session cookie"
}

remote_artifact_exists() {
  vps_ssh "test -f $(vps_remote_artifact_file)"
}

load_remote_artifact() {
  artifact_local="$(vps_local_artifact_cache)"
  vps_ssh "cat $(vps_remote_artifact_file)" > "$artifact_local" || fail "Не удалось прочитать Warren-артефакт с VPS"
  # shellcheck disable=SC1090
  . "$artifact_local"

  PANEL_USERNAME="${PANEL_USERNAME:-}"
  PANEL_PASSWORD="${PANEL_PASSWORD:-}"
  PANEL_URL="${PANEL_URL:-}"
  PANEL_SCHEME="${PANEL_SCHEME:-https}"
  VLESS_LINK="${VLESS_LINK:-}"
  INBOUND_ID="${INBOUND_ID:-}"
  PANEL_PORT="${PANEL_PORT:-2053}"
  PANEL_BASE_PATH="${PANEL_BASE_PATH:-}"
  REPORT_FILE="$(vps_report_file)"
}

save_remote_artifact() {
  artifact_local="$(vps_local_artifact_cache)"
  artifact_remote="$(vps_remote_artifact_file)"

  {
    printf "VPS_HOST=%s\n" "$(quote_sh "${VPS_HOST:-}")"
    printf "VPS_SSH_PORT=%s\n" "$(quote_sh "${VPS_SSH_PORT:-}")"
    printf "VPS_INSTANCE_ID=%s\n" "$(quote_sh "${VPS_INSTANCE_ID:-}")"
    printf "PANEL_URL=%s\n" "$(quote_sh "${PANEL_URL:-}")"
    printf "PANEL_SCHEME=%s\n" "$(quote_sh "${PANEL_SCHEME:-}")"
    printf "PANEL_PORT=%s\n" "$(quote_sh "${PANEL_PORT:-}")"
    printf "PANEL_BASE_PATH=%s\n" "$(quote_sh "${PANEL_BASE_PATH:-}")"
    printf "PANEL_USERNAME=%s\n" "$(quote_sh "${PANEL_USERNAME:-}")"
    printf "PANEL_PASSWORD=%s\n" "$(quote_sh "${PANEL_PASSWORD:-}")"
    printf "INBOUND_ID=%s\n" "$(quote_sh "${INBOUND_ID:-}")"
    printf "VLESS_LINK=%s\n" "$(quote_sh "${VLESS_LINK:-}")"
    printf "REALITY_PUBLIC_KEY=%s\n" "$(quote_sh "${REALITY_PUBLIC_KEY:-}")"
    printf "SID_PRIMARY=%s\n" "$(quote_sh "${SID_PRIMARY:-}")"
    printf "CLIENT_EMAIL=%s\n" "$(quote_sh "${CLIENT_EMAIL:-}")"
    printf "CLIENT_UUID=%s\n" "$(quote_sh "${CLIENT_UUID:-}")"
  } > "$artifact_local" || fail "Не удалось подготовить локальный Warren-артефакт"

  vps_ssh "mkdir -p $(vps_remote_state_dir)" || fail "Не удалось создать каталог Warren-артефактов на VPS"
  vps_write_remote_file "$artifact_local" "$artifact_remote" || fail "Не удалось сохранить Warren-артефакт на VPS"
}

handle_existing_vps_setup() {
  if ! is_3xui_installed; then
    return 1
  fi

  say "${YELLOW}INFO${NC}  На сервере уже найден установленный 3x-ui."
  if [ "${MODE:-}" = "auto" ] || [ "${WARREN_LUCI_REQUEST:-0}" = "1" ]; then
    EXISTING_3XUI_ACTION="${WARREN_EXISTING_3XUI_ACTION:-1}"
    case "$EXISTING_3XUI_ACTION" in
      1) say "${YELLOW}INFO${NC}  В неинтерактивном режиме переиспользую 3x-ui и пересоздам inbound." ;;
      2) say "${YELLOW}INFO${NC}  Запрошена контролируемая переустановка 3x-ui." ;;
      *) fail "WARREN_EXISTING_3XUI_ACTION должен быть 1 (reuse) или 2 (reinstall)" ;;
    esac
  else
    say "1) Пересоздать inbound"
    say "2) Починить: снести 3x-ui и поставить заново"
    ask "Выбор (1-2)" EXISTING_3XUI_ACTION "1"
  fi

  case "$EXISTING_3XUI_ACTION" in
    1)
      if remote_artifact_exists; then
        load_remote_artifact
        vps_step_done "Переиспользую текущую установку 3x-ui и сохранённые креды"
      else
        collect_3xui_access_info
        configure_3xui_admin
        collect_3xui_access_info
        vps_step_done "Переиспользую текущую установку 3x-ui, креды панели обновлены"
      fi
      return 1
      ;;
    2)
      return 2
      ;;
    *)
      fail "Введи 1 или 2"
      ;;
  esac
}

purge_3xui_installation() {
  info "Сношу текущую установку 3x-ui и связанные файлы..."
  vps_ssh "sh -lc '
    backup_dir=/root/warren-backups/3x-ui-\$(date +%Y%m%d-%H%M%S)
    mkdir -p \"\$backup_dir\"
    [ ! -d /etc/x-ui ] || cp -a /etc/x-ui \"\$backup_dir/etc-x-ui\"
    [ ! -d /root/.warren ] || cp -a /root/.warren \"\$backup_dir/root-warren\"
    printf \"%s\n\" \"\$backup_dir\" > /tmp/warren-3xui-backup-path
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop x-ui >/dev/null 2>&1 || true
      systemctl disable x-ui >/dev/null 2>&1 || true
      systemctl stop x-ui.service >/dev/null 2>&1 || true
      systemctl disable x-ui.service >/dev/null 2>&1 || true
    fi
    pkill -x x-ui >/dev/null 2>&1 || true
    pkill -x xray-linux-amd64 >/dev/null 2>&1 || true
    rm -rf /usr/local/x-ui /etc/x-ui /var/lib/x-ui /root/.warren /root/cert/ip
    rm -f /usr/bin/x-ui /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service
    rm -f /tmp/warren-3xui-install.log /tmp/warren-3xui-install.rc /tmp/warren-3xui-install.sh
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  '" || fail "Не удалось удалить текущую установку 3x-ui"

  rm -f "$(vps_local_artifact_cache)" 2>/dev/null || true
  unset PANEL_USERNAME PANEL_PASSWORD PANEL_URL PANEL_PORT PANEL_BASE_PATH VLESS_LINK INBOUND_ID
  backup_path="$(vps_ssh "cat /tmp/warren-3xui-backup-path 2>/dev/null || true")"
  vps_step_done "Старая установка 3x-ui удалена; backup: ${backup_path:-unknown}"
}
