ensure_vps_prereqs() {
  missing=""
  command -v ssh >/dev/null 2>&1 || missing="$missing openssh-client"
  command -v sshpass >/dev/null 2>&1 || missing="$missing sshpass"

  if [ -n "$missing" ]; then
    info "Для работы с VPS нужны пакеты:$missing"
    opkg update
    opkg install $missing || fail "Не удалось установить пакеты для VPS-модуля:$missing"
  fi
}

collect_vps_inputs() {
  if [ -z "${VPS_HOST:-}" ]; then
    ask "IP адрес VPS" VPS_HOST ""
    [ -n "$VPS_HOST" ] || fail "IP адрес VPS пустой"
    conf_set VPS_HOST "$VPS_HOST"
  fi

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

vps_ssh() {
  sshpass -p "$VPS_ROOT_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 \
    -p "$VPS_SSH_PORT" \
    "root@$VPS_HOST" "$@"
}

probe_vps_access() {
  info "Проверяю SSH доступ к VPS..."
  out="$(vps_ssh "printf '__WARREN_VPS_OK__\n'")" || fail "Не удалось подключиться к VPS по SSH. Проверь IP, порт и пароль."
  printf "%s" "$out" | grep -q "__WARREN_VPS_OK__" || fail "VPS ответил неожиданно. Проверь SSH доступ."
  done_ "SSH доступ к VPS подтверждён"
}

collect_vps_facts() {
  info "Снимаю базовую информацию о VPS..."
  facts="$(vps_ssh "uname -srm; printf '__OS_RELEASE__\n'; sed -n '1,6p' /etc/os-release 2>/dev/null || true")" || fail "Не удалось получить информацию о VPS"
  runtime_state_set "vps_facts" "$facts"
  say ""
  say "=== VPS facts ==="
  printf "%s\n" "$facts"
  say ""
  done_ "Базовая информация о VPS собрана"
}

run_vps_flow() {
  say ""
  say "Подготовка доступа к VPS"
  ensure_vps_prereqs
  collect_vps_inputs
  probe_vps_access
  collect_vps_facts
  say "${YELLOW}NEXT${NC}  Следующим этапом сюда добавим установку 3x-ui и настройку VLESS + Reality."
}
