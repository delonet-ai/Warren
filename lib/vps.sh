# VPS setup flow: progress UI, inputs, prerequisites and run_vps_flow.
# Building blocks: vps_report.sh, vps_ssh.sh, vps_3xui.sh, vps_reality.sh.

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
  vps_progress_line 7 "$step" "Remote Admin"
  vps_progress_line 8 "$step" "Вывод логина и пароля UI"
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

ensure_vps_prereqs() {
  missing=""
  command -v ssh >/dev/null 2>&1 || missing="$missing openssh-client"
  command -v sshpass >/dev/null 2>&1 || missing="$missing sshpass"
  command -v ssh-keygen >/dev/null 2>&1 || missing="$missing openssh-keygen"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    if pkg_manager >/dev/null 2>&1; then
      info "Для работы с VPS нужны пакеты:$missing"
      # shellcheck disable=SC2086
      pkg_ensure_installed $missing
    else
      fail "Не хватает локальных утилит:$missing. Установите их вручную и запустите снова."
    fi
  fi
}

collect_vps_inputs() {
  mkdir -p "$(vps_workspace_dir)" "$(vps_keys_dir)" "$(vps_reports_dir)" || fail "Не удалось создать локальные каталоги для VPS-модуля"

  if [ "${MODE:-}" = "auto" ] && [ -n "${VPS_HOST:-}" ] && [ -n "${VPS_ROOT_PASSWORD:-}" ]; then
    [ -n "${VPS_SSH_PORT:-}" ] || VPS_SSH_PORT="22"
    say "${GREEN}DONE${NC}  Использую заранее сохранённые данные VPS для авторежима: ${VPS_HOST}:${VPS_SSH_PORT}"
  else
    ask "IP адрес VPS" VPS_HOST "${VPS_HOST:-}"
    [ -n "$VPS_HOST" ] || fail "IP адрес VPS пустой"

    if [ -z "${VPS_SSH_PORT:-}" ]; then
      VPS_SSH_PORT="22"
    fi
    ask "SSH порт VPS" VPS_SSH_PORT "${VPS_SSH_PORT:-22}"
    [ -n "$VPS_SSH_PORT" ] || fail "SSH порт VPS пустой"

    ask "Root пароль VPS" VPS_ROOT_PASSWORD "${VPS_ROOT_PASSWORD:-}"
    [ -n "$VPS_ROOT_PASSWORD" ] || fail "Root пароль VPS пустой"
  fi

  conf_set VPS_HOST "$VPS_HOST"
  conf_set VPS_SSH_PORT "$VPS_SSH_PORT"
  conf_set VPS_ROOT_PASSWORD "$VPS_ROOT_PASSWORD"

  if [ "${MODE:-}" != "auto" ]; then
    init_runtime_state
  fi
  runtime_state_set "mode" "${MODE:-vps}"
  runtime_state_set "auto_vps_source" "${AUTO_VPS_SOURCE:-}"
  runtime_state_set "vps_host" "$VPS_HOST"
  runtime_state_set "vps_ssh_port" "$VPS_SSH_PORT"
  runtime_state_set "vps_root_password" "$VPS_ROOT_PASSWORD"
}

vps_forget_root_password() {
  VPS_ROOT_PASSWORD=""
  conf_set VPS_ROOT_PASSWORD ""
  if [ -n "${AUTO_STATE_STORE:-}" ]; then
    runtime_state_set "vps_root_password" ""
  fi
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
  if [ -n "${REMOTE_ADMIN_ROUTER_ID:-}" ] || [ -n "${REMOTE_ADMIN_ENDPOINTS:-}" ]; then
    say ""
    remote_admin_summary
  fi
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
  ensure_3xui_api_token || info "API token 3x-ui недоступен; будет использована session cookie"
  configure_vless_reality

  vps_step_start 7
  info "Добавляю Remote Admin в установку VPS..."
  remote_admin_install_vps_bundle || fail "Не удалось добавить Remote Admin в установку VPS"

  vps_step_start 8
  print_vps_summary
  notify_vps_report_via_tg "${REPORT_FILE:-}"
  vps_forget_root_password
  vps_step_done "Логин и пароль UI выведены"
}
