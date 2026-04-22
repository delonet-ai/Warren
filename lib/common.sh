GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

say() {
  printf "%b\n" "$*"
}

done_() {
  say "${GREEN}DONE${NC}  $*"
  case "${MODE:-}" in
    vps|podkop_backup|qos_private|remote_admin|usb_modem|tg_bot|diagnostics|manage_private)
      ;;
    *)
      print_progress
      ;;
  esac
  sleep 5
}

info() {
  say "${YELLOW}INFO${NC}  $*"
}

warn() {
  say "${YELLOW}WARN${NC}  $*"
  sleep 5
}

fail() {
  say "${RED}FAIL${NC}  $*"
  exit 1
}

log() {
  echo "[$(date +'%F %T')] $*" >> "$LOG"
}

quote_sh() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

download_file() {
  url="$1"
  out="$2"
  expected_sha="$3"
  label="$4"

  wget -qO "$out" "$url" || fail "Не удалось скачать $label: $url"

  if [ -n "$expected_sha" ]; then
    actual_sha="$(sha256sum "$out" | awk '{print $1}')"
    [ "$actual_sha" = "$expected_sha" ] || fail "SHA256 mismatch для $label: ожидался $expected_sha, получен $actual_sha"
  else
    warn "$label скачан без SHA256-проверки. Для жёсткой верификации задай ${label}_SHA256."
  fi
}

uciq() {
  uci -q "$@"
}
