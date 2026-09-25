# SSH transport to the VPS: password/key auth, timeouts, file upload, key exchange.

vps_key_file() {
  key_name="$(vps_sanitized_host)"
  if [ -n "${VPS_INSTANCE_ID:-}" ]; then
    inst="$(printf "%s" "$VPS_INSTANCE_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-24)"
    key_name="${key_name}_${inst}"
  fi
  printf "%s/%s_ed25519" "$(vps_keys_dir)" "$key_name"
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
