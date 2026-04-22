vps_progress_stage() {
  step="${1:-0}"
  say ""
  say "┌──────────────────────── VPS Progress ────────────────────────┐"
  vps_progress_line 1 "$step" "Сбор кредов"
  vps_progress_line 2 "$step" "Проверка доступа по SSH"
  vps_progress_line 3 "$step" "Обмен SSH-ключами"
  vps_progress_line 4 "$step" "Определение ОС и апгрейд пакетов"
  vps_progress_line 5 "$step" "Установка 3x-ui"
  vps_progress_line 6 "$step" "Конфигурация VLESS + Reality"
  vps_progress_line 7 "$step" "Вывод логина и пароля UI"
  say "└──────────────────────────────────────────────────────────────┘"
  say ""
}

vps_progress_line() {
  idx="$1"
  current="$2"
  title="$3"

  if [ "$idx" -lt "$current" ]; then
    say "  ${GREEN}✅${NC} $title"
  elif [ "$idx" -eq "$current" ]; then
    say "  ${YELLOW}⏳${NC} $title"
  else
    say "  ⬜ $title"
  fi
}

vps_step_start() {
  VPS_CURRENT_STEP="$1"
  vps_progress_stage "$VPS_CURRENT_STEP"
}

vps_step_done() {
  say "${GREEN}DONE${NC}  $*"
  say "${YELLOW}INFO${NC}  Процесс продолжается, пожалуйста подождите 5 секунд..."
  sleep 5
}

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
  find "$reports_dir" -maxdepth 1 -type f -name '*.txt' | sort
}

vps_report_vless_link() {
  report_file="$1"
  [ -r "$report_file" ] || return 1
  sed -n 's/^VLESS inbound link: //p' "$report_file" | head -n1
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

vps_key_file() {
  key_name="$(vps_sanitized_host)"
  if [ -n "${VPS_INSTANCE_ID:-}" ]; then
    inst="$(printf "%s" "$VPS_INSTANCE_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-24)"
    key_name="${key_name}_${inst}"
  fi
  printf "%s/%s_ed25519" "$(vps_keys_dir)" "$key_name"
}

random_token() {
  len="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((len * 2)) | tr -dc 'A-Za-z0-9' | head -c "$len"
  else
    date +%s | tr -dc 'A-Za-z0-9' | head -c "$len"
  fi
}

random_hex() {
  len="${1:-8}"
  if command -v openssl >/dev/null 2>&1; then
    bytes=$(((len + 1) / 2))
    openssl rand -hex "$bytes" | cut -c1-"$len"
  else
    date +%s | tr -dc 'a-f0-9' | head -c "$len"
  fi
}

vps_client_name() {
  printf "%s" "${VPS_HOST:-warren}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//'
}

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

vps_remote_state_dir() {
  printf "%s" "/root/.warren"
}

vps_remote_artifact_file() {
  printf "%s/3xui.env" "$(vps_remote_state_dir)"
}

vps_local_artifact_cache() {
  printf "%s/%s.env" "$(vps_workspace_dir)" "$(vps_sanitized_host)"
}

ensure_vps_prereqs() {
  missing=""
  command -v ssh >/dev/null 2>&1 || missing="$missing openssh-client"
  command -v sshpass >/dev/null 2>&1 || missing="$missing sshpass"
  command -v ssh-keygen >/dev/null 2>&1 || missing="$missing openssh-keygen"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    if command -v opkg >/dev/null 2>&1; then
      info "Для работы с VPS нужны пакеты:$missing"
      opkg update
      opkg install $missing || fail "Не удалось установить пакеты для VPS-модуля:$missing"
    else
      fail "Не хватает локальных утилит:$missing. Установите их вручную и запустите снова."
    fi
  fi
}

is_3xui_installed() {
  vps_ssh "test -x /usr/local/x-ui/x-ui"
}

collect_vps_inputs() {
  mkdir -p "$(vps_workspace_dir)" "$(vps_keys_dir)" "$(vps_reports_dir)" || fail "Не удалось создать локальные каталоги для VPS-модуля"

  ask "IP адрес VPS" VPS_HOST "${VPS_HOST:-}"
  [ -n "$VPS_HOST" ] || fail "IP адрес VPS пустой"
  conf_set VPS_HOST "$VPS_HOST"

  if [ -z "${VPS_SSH_PORT:-}" ]; then
    VPS_SSH_PORT="22"
  fi
  ask "SSH порт VPS" VPS_SSH_PORT "${VPS_SSH_PORT:-22}"
  [ -n "$VPS_SSH_PORT" ] || fail "SSH порт VPS пустой"
  conf_set VPS_SSH_PORT "$VPS_SSH_PORT"

  ask "Root пароль VPS" VPS_ROOT_PASSWORD ""
  [ -n "$VPS_ROOT_PASSWORD" ] || fail "Root пароль VPS пустой"

  init_runtime_state
  runtime_state_set "mode" "${MODE:-vps}"
  runtime_state_set "vps_host" "$VPS_HOST"
  runtime_state_set "vps_ssh_port" "$VPS_SSH_PORT"
  runtime_state_set "vps_root_password" "$VPS_ROOT_PASSWORD"
}

vps_ssh_local_timeout() {
  timeout_seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "$@"
  else
    "$@"
  fi
}

vps_is_dropbear_ssh() {
  if ssh -V 2>&1 | grep -qi dropbear; then
    return 0
  fi
  return 1
}

vps_ssh_password_timeout() {
  timeout_seconds="$1"
  shift

  if vps_is_dropbear_ssh; then
    vps_ssh_local_timeout "$timeout_seconds" sshpass -p "$VPS_ROOT_PASSWORD" ssh \
      -y \
      -p "$VPS_SSH_PORT" \
      "root@$VPS_HOST" "$@" < /dev/null
  else
    vps_ssh_local_timeout "$timeout_seconds" sshpass -p "$VPS_ROOT_PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=20 \
      -p "$VPS_SSH_PORT" \
      "root@$VPS_HOST" "$@" < /dev/null
  fi
}

vps_ssh_password() {
  vps_ssh_password_timeout "${VPS_SSH_TIMEOUT:-120}" "$@"
}

vps_ssh_key_timeout() {
  timeout_seconds="$1"
  shift

  if vps_is_dropbear_ssh; then
    vps_ssh_local_timeout "$timeout_seconds" ssh \
      -y \
      -i "$VPS_KEY_PATH" \
      -p "$VPS_SSH_PORT" \
      "root@$VPS_HOST" "$@" < /dev/null
  else
    vps_ssh_local_timeout "$timeout_seconds" ssh \
      -i "$VPS_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o ConnectTimeout=20 \
      -p "$VPS_SSH_PORT" \
      "root@$VPS_HOST" "$@" < /dev/null
  fi
}

vps_ssh_key() {
  vps_ssh_key_timeout "${VPS_SSH_TIMEOUT:-120}" "$@"
}

vps_ssh_timeout() {
  timeout_seconds="$1"
  shift

  if [ -n "${VPS_KEY_PATH:-}" ] && [ -r "$VPS_KEY_PATH" ]; then
    vps_ssh_key_timeout "$timeout_seconds" "$@"
  else
    vps_ssh_password_timeout "$timeout_seconds" "$@"
  fi
}

vps_ssh() {
  vps_ssh_timeout "${VPS_SSH_TIMEOUT:-120}" "$@"
}

vps_write_remote_file() {
  local_file="$1"
  remote_file="$2"

  if [ -n "${VPS_KEY_PATH:-}" ] && [ -r "$VPS_KEY_PATH" ]; then
    if vps_is_dropbear_ssh; then
      vps_ssh_local_timeout 90 ssh \
        -y \
        -i "$VPS_KEY_PATH" \
        -p "$VPS_SSH_PORT" \
        "root@$VPS_HOST" "cat > $remote_file" < "$local_file"
    else
      vps_ssh_local_timeout 90 ssh \
        -i "$VPS_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o PreferredAuthentications=publickey \
        -o PasswordAuthentication=no \
        -o ConnectTimeout=8 \
        -p "$VPS_SSH_PORT" \
        "root@$VPS_HOST" "cat > $remote_file" < "$local_file"
    fi
  else
    if vps_is_dropbear_ssh; then
      vps_ssh_local_timeout 90 sshpass -p "$VPS_ROOT_PASSWORD" ssh \
        -y \
        -p "$VPS_SSH_PORT" \
        "root@$VPS_HOST" "cat > $remote_file" < "$local_file"
    else
      vps_ssh_local_timeout 90 sshpass -p "$VPS_ROOT_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=8 \
        -p "$VPS_SSH_PORT" \
        "root@$VPS_HOST" "cat > $remote_file" < "$local_file"
    fi
  fi
}

probe_vps_access() {
  info "Проверяю SSH доступ к VPS..."
  out="$(vps_ssh_password "printf '__WARREN_VPS_OK__\n'")" || fail "Не удалось подключиться к VPS по SSH. Проверь IP, порт и пароль."
  printf "%s" "$out" | grep -q "__WARREN_VPS_OK__" || fail "VPS ответил неожиданно. Проверь SSH доступ."
  VPS_INSTANCE_ID="$(vps_ssh_password "sh -lc 'cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || hostname'" | tr -d '\r' | head -n1)"
  runtime_state_set "vps_instance_id" "$VPS_INSTANCE_ID"
  vps_step_done "SSH доступ к VPS подтверждён"
}

exchange_vps_keys() {
  VPS_KEY_PATH="$(vps_key_file)"
  runtime_state_set "vps_key_path" "$VPS_KEY_PATH"

  if [ ! -f "$VPS_KEY_PATH" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "$VPS_KEY_PATH" || fail "Не удалось сгенерировать SSH-ключ для VPS"
  fi

  pubkey="$(cat "$VPS_KEY_PATH.pub")"
  quoted_pubkey="$(quote_sh "$pubkey")"

  vps_ssh_password "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; grep -qxF $quoted_pubkey /root/.ssh/authorized_keys || printf '%s\n' $quoted_pubkey >> /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys" \
    || fail "Не удалось установить SSH-ключ на VPS"

  out="$(vps_ssh_key "printf '__WARREN_VPS_KEY_OK__\n'")" || fail "Не удалось проверить SSH-доступ по ключу"
  printf "%s" "$out" | grep -q "__WARREN_VPS_KEY_OK__" || fail "Ключевой SSH-доступ не подтвердился"
  vps_step_done "SSH-ключ установлен, дальнейший доступ будет без пароля"
}

detect_vps_os() {
  os_info="$(vps_ssh "sh -lc '. /etc/os-release 2>/dev/null && printf \"%s|%s|%s\n\" \"\${ID:-unknown}\" \"\${VERSION_ID:-unknown}\" \"\${PRETTY_NAME:-unknown}\"'")" \
    || fail "Не удалось определить ОС на VPS"
  VPS_OS_ID="$(printf "%s" "$os_info" | awk -F'|' '{print $1}')"
  VPS_OS_VERSION="$(printf "%s" "$os_info" | awk -F'|' '{print $2}')"
  VPS_OS_PRETTY="$(printf "%s" "$os_info" | awk -F'|' '{print $3}')"
  runtime_state_set "vps_os_id" "$VPS_OS_ID"
  runtime_state_set "vps_os_version" "$VPS_OS_VERSION"
  runtime_state_set "vps_os_pretty" "$VPS_OS_PRETTY"
}

upgrade_vps_packages() {
  case "$VPS_OS_ID" in
    ubuntu|debian|raspbian|armbian)
      vps_ssh_timeout 1800 "sh -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y && apt-get install -y curl ca-certificates coreutils procps'" \
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
  vps_ssh_timeout 1200 "sh -lc '
    log=/tmp/warren-3xui-install.log
    rcfile=/tmp/warren-3xui-install.rc
    installer=/tmp/warren-3xui-install.sh
    rm -f \"\$log\" \"\$rcfile\" \"\$installer\"

    echo \"__WARREN_STEP__ download installer\" >\"\$log\"
    curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o \"\$installer\" >>\"\$log\" 2>&1
    chmod +x \"\$installer\"

    (
      echo \"__WARREN_STEP__ run installer\"
      export DEBIAN_FRONTEND=noninteractive
      if command -v timeout >/dev/null 2>&1; then
        timeout 900 bash \"\$installer\" < /dev/null
        install_rc=\$?
      else
        bash \"\$installer\" < /dev/null
        install_rc=\$?
      fi
      echo \"\$install_rc\" > \"\$rcfile\"
      echo \"__WARREN_INSTALL_RC__ \$install_rc\"
    ) >>\"\$log\" 2>&1 &
    installer_pid=\$!

    elapsed=0
    ready=0
    while [ \"\$elapsed\" -lt 900 ]; do
      if [ -f \"\$rcfile\" ]; then
        break
      fi

      if [ -x /usr/local/x-ui/x-ui ]; then
        if command -v systemctl >/dev/null 2>&1; then
          if [ -f /etc/systemd/system/x-ui.service ] && systemctl is-active --quiet x-ui >/dev/null 2>&1; then
            ready=1
            break
          fi
        elif pgrep -f /usr/local/x-ui/x-ui >/dev/null 2>&1; then
          ready=1
          break
        fi
      fi

      sleep 2
      elapsed=\$((elapsed + 2))
    done

    if [ \"\$ready\" = \"1\" ] && [ ! -f \"\$rcfile\" ]; then
      echo \"Warren: 3x-ui is installed and running; stopping possibly stuck installer pid \$installer_pid\" >>\"\$log\"
      pkill -P \"\$installer_pid\" >/dev/null 2>&1 || true
      kill \"\$installer_pid\" >/dev/null 2>&1 || true
      sleep 1
      pkill -9 -P \"\$installer_pid\" >/dev/null 2>&1 || true
      kill -9 \"\$installer_pid\" >/dev/null 2>&1 || true
    fi

    tail -n 180 \"\$log\" 2>/dev/null || true

    if [ -f \"\$rcfile\" ]; then
      install_rc=\"\$(cat \"\$rcfile\" 2>/dev/null || echo 1)\"
      if [ \"\$install_rc\" != \"0\" ] && [ \"\$install_rc\" != \"124\" ]; then
        echo \"Warren: 3x-ui installer failed with rc=\$install_rc\"
        exit \"\$install_rc\"
      fi
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
  raw_base="$(printf "%s" "${1:-}" | tr -d '[:space:]')"
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
      if vps_ssh_timeout 20 "sh -lc 'code=\"\$(curl -ksS -o /dev/null -w \"%{http_code}\" --connect-timeout 3 --max-time 8 https://127.0.0.1:${PANEL_PORT}${panel_path} 2>/dev/null || true)\"; case \"\$code\" in 2*|3*) exit 0 ;; *) exit 1 ;; esac'"; then
        PANEL_SCHEME="https"
        PANEL_HEALTH_PATH="$panel_path"
        return 0
      fi
      if vps_ssh_timeout 20 "sh -lc 'code=\"\$(curl -sS -o /dev/null -w \"%{http_code}\" --connect-timeout 3 --max-time 8 http://127.0.0.1:${PANEL_PORT}${panel_path} 2>/dev/null || true)\"; case \"\$code\" in 2*|3*) exit 0 ;; *) exit 1 ;; esac'"; then
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

login_3xui_api() {
  login_json_local="$(vps_workspace_dir)/panel-login.json"
  login_json_remote="/tmp/warren-panel-login.json"
  PANEL_COOKIE_REMOTE="/tmp/warren-panel.cookie"

  {
    printf '{"username":"%s","password":"%s"}\n' "$(json_escape "$PANEL_USERNAME")" "$(json_escape "$PANEL_PASSWORD")"
  } > "$login_json_local" || fail "Не удалось подготовить login payload для 3x-ui"

  vps_write_remote_file "$login_json_local" "$login_json_remote" || fail "Не удалось загрузить login payload на VPS"

  panel_scheme="${PANEL_SCHEME:-https}"
  curl_tls_flag=""
  [ "$panel_scheme" = "https" ] && curl_tls_flag="-k"
  PANEL_CURL_FLAGS="$curl_tls_flag --http1.1"
  PANEL_API_BASE="${panel_scheme}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"

  login_resp="$(vps_ssh_timeout 60 "sh -lc 'curl $PANEL_CURL_FLAGS -fsS --connect-timeout 5 --max-time 20 -c $PANEL_COOKIE_REMOTE -H \"Content-Type: application/json\" -X POST --data @$login_json_remote ${PANEL_API_BASE}/login'")" \
    || fail "Не удалось войти в API 3x-ui"

  printf "%s" "$login_resp" | grep -qi "success\|ok\|true" || fail "3x-ui login API вернул неожиданный ответ"
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
  say "1) Пересоздать inbound"
  say "2) Починить: снести 3x-ui и поставить заново"
  ask "Выбор (1-2)" EXISTING_3XUI_ACTION "1"

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
  vps_step_done "Старая установка 3x-ui удалена"
}

generate_reality_materials() {
  panel_curl_flags="${PANEL_CURL_FLAGS:---http1.1}"
  panel_api_base="${PANEL_API_BASE:-${PANEL_SCHEME:-https}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}}"

  cert_resp="$(vps_ssh_timeout 60 "sh -lc 'curl $panel_curl_flags -fsS --connect-timeout 5 --max-time 30 -b $PANEL_COOKIE_REMOTE ${panel_api_base}/panel/api/server/getNewX25519Cert'")" \
    || fail "Не удалось сгенерировать X25519 ключи через API 3x-ui"

  REALITY_PRIVATE_KEY="$(printf "%s" "$cert_resp" | json_get_string "privateKey")"
  REALITY_PUBLIC_KEY="$(printf "%s" "$cert_resp" | json_get_string "publicKey")"
  [ -n "$REALITY_PRIVATE_KEY" ] || fail "API 3x-ui не вернул privateKey для Reality"
  [ -n "$REALITY_PUBLIC_KEY" ] || fail "API 3x-ui не вернул publicKey для Reality"

  CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)"
  [ -n "$CLIENT_UUID" ] || CLIENT_UUID="$(random_hex 8)-$(random_hex 4)-4$(random_hex 3)-a$(random_hex 3)-$(random_hex 12)"
  CLIENT_EMAIL="$(random_token 8)"
  CLIENT_SUBID="$(random_token 16)"
  CLIENT_COMMENT="$(vps_client_name)"

  SID_PRIMARY="$(random_hex 14)"
  SID_EXTRA_1="$(random_hex 16)"
  SID_EXTRA_2="$(random_hex 4)"
  SID_EXTRA_3="$(random_hex 8)"
  SID_EXTRA_4="$(random_hex 2)"
  SID_EXTRA_5="$(random_hex 10)"
  SID_EXTRA_6="$(random_hex 6)"
  SID_EXTRA_7="$(random_hex 12)"

  runtime_state_set "reality_private_key" "$REALITY_PRIVATE_KEY"
  runtime_state_set "reality_public_key" "$REALITY_PUBLIC_KEY"
  runtime_state_set "client_uuid" "$CLIENT_UUID"
  runtime_state_set "client_email" "$CLIENT_EMAIL"
  runtime_state_set "client_subid" "$CLIENT_SUBID"
  runtime_state_set "reality_sid" "$SID_PRIMARY"
}

create_vless_reality_payload() {
  INBOUND_REMARK="warren-reality"
  INBOUND_TAG="inbound-443"
  INBOUND_PORT="443"
  REALITY_TARGET="login.vk.com:443"
  REALITY_SERVER_NAME_1="login.vk.com"
  REALITY_SERVER_NAME_2="www.login.vk.com"
  REALITY_FINGERPRINT="chrome"
  REALITY_SPIDERX="/"
  CLIENT_FLOW="xtls-rprx-vision"

  inbound_json_local="$(vps_workspace_dir)/inbound-vless-reality.json"
  inbound_json_remote="/tmp/warren-inbound-vless-reality.json"

  cat > "$inbound_json_local" <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "remark": "${INBOUND_REMARK}",
  "enable": true,
  "expiryTime": 0,
  "listen": "",
  "port": ${INBOUND_PORT},
  "protocol": "vless",
  "settings": "{\"clients\":[{\"comment\":\"${CLIENT_COMMENT}\",\"email\":\"${CLIENT_EMAIL}\",\"enable\":true,\"expiryTime\":0,\"flow\":\"${CLIENT_FLOW}\",\"id\":\"${CLIENT_UUID}\",\"limitIp\":0,\"reset\":0,\"subId\":\"${CLIENT_SUBID}\",\"tgId\":\"\",\"totalGB\":0}],\"decryption\":\"none\",\"encryption\":\"none\"}",
  "streamSettings": "{\"network\":\"tcp\",\"security\":\"reality\",\"externalProxy\":[],\"realitySettings\":{\"show\":false,\"xver\":0,\"target\":\"${REALITY_TARGET}\",\"serverNames\":[\"${REALITY_SERVER_NAME_1}\",\"${REALITY_SERVER_NAME_2}\"],\"privateKey\":\"${REALITY_PRIVATE_KEY}\",\"minClientVer\":\"\",\"maxClientVer\":\"\",\"maxTimediff\":0,\"shortIds\":[\"${SID_PRIMARY}\",\"${SID_EXTRA_1}\",\"${SID_EXTRA_2}\",\"${SID_EXTRA_3}\",\"${SID_EXTRA_4}\",\"${SID_EXTRA_5}\",\"${SID_EXTRA_6}\",\"${SID_EXTRA_7}\"],\"mldsa65Seed\":\"\",\"settings\":{\"publicKey\":\"${REALITY_PUBLIC_KEY}\",\"fingerprint\":\"${REALITY_FINGERPRINT}\",\"serverName\":\"\",\"spiderX\":\"${REALITY_SPIDERX}\",\"mldsa65Verify\":\"\"}},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}",
  "tag": "${INBOUND_TAG}",
  "sniffing": "{\"enabled\":false,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"
}
EOF

  vps_write_remote_file "$inbound_json_local" "$inbound_json_remote" || fail "Не удалось загрузить inbound payload на VPS"
}

create_vless_reality_inbound() {
  panel_curl_flags="${PANEL_CURL_FLAGS:---http1.1}"
  panel_api_base="${PANEL_API_BASE:-${PANEL_SCHEME:-https}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}}"

  if [ -n "${INBOUND_ID:-}" ]; then
    vps_ssh_timeout 60 "sh -lc 'curl $panel_curl_flags -fsS --connect-timeout 5 --max-time 30 -b $PANEL_COOKIE_REMOTE -X POST ${panel_api_base}/panel/api/inbounds/del/${INBOUND_ID} >/dev/null'" \
      || fail "Не удалось удалить предыдущий inbound перед пересозданием"
  fi

  add_resp="$(vps_ssh_timeout 60 "sh -lc 'curl $panel_curl_flags -fsS --connect-timeout 5 --max-time 30 -b $PANEL_COOKIE_REMOTE -H \"Content-Type: application/json\" -X POST --data @$inbound_json_remote ${panel_api_base}/panel/api/inbounds/add'")" \
    || fail "Не удалось создать VLESS + Reality inbound через API 3x-ui"

  printf "%s" "$add_resp" | json_has_success_true || fail "API 3x-ui не подтвердил создание inbound"
  INBOUND_ID="$(printf "%s" "$add_resp" | json_get_number "id")"
  runtime_state_set "inbound_id" "$INBOUND_ID"
}

build_vless_link() {
  VLESS_LINK="vless://${CLIENT_UUID}@${VPS_HOST}:${INBOUND_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=${REALITY_FINGERPRINT}&sni=${REALITY_SERVER_NAME_1}&sid=${SID_PRIMARY}&spx=%2F&flow=${CLIENT_FLOW}#${CLIENT_COMMENT}"
  runtime_state_set "vless_link" "$VLESS_LINK"
}

configure_vless_reality() {
  login_3xui_api
  generate_reality_materials
  create_vless_reality_payload
  create_vless_reality_inbound
  build_vless_link

  REPORT_FILE="$(vps_report_file)"
  runtime_state_set "vps_report_file" "$REPORT_FILE"

  {
    printf "Warren VPS setup report\n"
    printf "=======================\n\n"
    printf "VLESS inbound link: %s\n\n" "${VLESS_LINK:-unknown}"
    printf "Host: %s\n" "$VPS_HOST"
    printf "SSH port: %s\n" "$VPS_SSH_PORT"
    printf "OS: %s\n" "${VPS_OS_PRETTY:-unknown}"
    printf "3x-ui URL: %s\n" "${PANEL_URL:-unknown}"
    printf "3x-ui username: %s\n" "${PANEL_USERNAME:-unknown}"
    printf "3x-ui password: %s\n" "${PANEL_PASSWORD:-unknown}"
    printf "\nReality public key: %s\n" "${REALITY_PUBLIC_KEY:-unknown}"
    printf "Reality short id: %s\n" "${SID_PRIMARY:-unknown}"
    printf "Client email: %s\n" "${CLIENT_EMAIL:-unknown}"
    printf "Client uuid: %s\n" "${CLIENT_UUID:-unknown}"
    printf "Reality config status: %s\n" "created"
  } > "$REPORT_FILE" || fail "Не удалось записать локальный отчёт по VPS"

  save_remote_artifact
  vps_step_done "VLESS + Reality inbound создан, локальный отчёт записан: $REPORT_FILE"
}

print_vps_summary() {
  say ""
  say "=== 3x-ui access ==="
  say "URL: ${PANEL_URL:-unknown}"
  say "Login: ${PANEL_USERNAME:-unknown}"
  say "Password: ${PANEL_PASSWORD:-unknown}"
  say "VLESS: ${VLESS_LINK:-unknown}"
  say "Local report: ${REPORT_FILE:-$(vps_report_file)}"
  say "Open report: nano ${REPORT_FILE:-$(vps_report_file)}"
  say ""
  say "${YELLOW}INFO${NC}  Для Reality на inbound отдельный TLS-сертификат не нужен: используются X25519 ключи."
}

collect_vps_facts() {
  info "Снимаю базовую информацию о VPS..."
  facts="$(vps_ssh "uname -srm; printf '__OS_RELEASE__\n'; sed -n '1,6p' /etc/os-release 2>/dev/null || true")" || fail "Не удалось получить информацию о VPS"
  runtime_state_set "vps_facts" "$facts"
  say ""
  say "=== VPS facts ==="
  printf "%s\n" "$facts"
  say ""
  vps_step_done "Базовая информация о VPS собрана"
}

run_vps_flow() {
  say ""
  say "Подготовка доступа к VPS"

  ensure_vps_prereqs

  vps_step_start 1
  collect_vps_inputs

  vps_step_start 2
  probe_vps_access

  vps_step_start 3
  exchange_vps_keys

  vps_step_start 4
  detect_vps_os
  upgrade_vps_packages
  collect_vps_facts

  if handle_existing_vps_setup; then
    existing_action_result=0
  else
    existing_action_result=$?
  fi
  case "$existing_action_result" in
    0)
      return 0
      ;;
    2)
      vps_step_start 5
      purge_3xui_installation
      install_3xui
      configure_3xui_admin
      collect_3xui_access_info
      ;;
    *)
      vps_step_start 5
      if [ -z "${PANEL_USERNAME:-}" ] || [ -z "${PANEL_PASSWORD:-}" ]; then
        if ! is_3xui_installed; then
          install_3xui
        fi
        configure_3xui_admin
        collect_3xui_access_info
      else
        vps_step_done "3x-ui переиспользуется без переустановки"
      fi
      ;;
  esac

  vps_step_start 6
  collect_3xui_access_info
  configure_vless_reality

  vps_step_start 7
  print_vps_summary
  vps_step_done "Логин и пароль UI выведены"
}
