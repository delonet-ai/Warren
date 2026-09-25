#!/bin/sh
# Backward-compatible wrapper. Prefer warren.sh.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo ".")"

if [ -r "$SCRIPT_DIR/warren.sh" ]; then
  exec sh "$SCRIPT_DIR/warren.sh" "$@"
fi

TMP_MAIN="/tmp/warren.sh"
TMP_VERSION="/tmp/warren-version.$$"
TMP_SUMS="/tmp/warren-sums.$$"
RAW_BASE="${WARREN_RAW_BASE_URL:-https://raw.githubusercontent.com/delonet-ai/Warren/main}"

cleanup_bootstrap() {
  rm -f "$TMP_VERSION" "$TMP_SUMS" 2>/dev/null || true
}
trap cleanup_bootstrap EXIT HUP INT TERM

bootstrap_fetch() {
  url="$1"
  out="$2"
  label="$3"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if [ "$attempt" -gt 1 ]; then
      case "$attempt" in
        2) delay=5 ;;
        *) delay=15 ;;
      esac
      printf "%s\n" "Повтор загрузки ${attempt}/3: $label (задержка ${delay}s)" >&2
      sleep "$delay"
    fi
    rm -f "$out" 2>/dev/null || true
    wget -T 20 -qO "$out" "$url" 2>/dev/null && return 0
    attempt=$((attempt + 1))
  done
  return 1
}

bootstrap_fetch "$RAW_BASE/VERSION" "$TMP_VERSION" "Warren VERSION" ||
  {
    printf "%s\n" "Не удалось скачать VERSION" >&2
    exit 1
  }

if [ "${WARREN_SKIP_HASH_CHECK:-0}" != "1" ]; then
  expected_sums="$(sed -n 's/^SUMS_SHA256=//p' "$TMP_VERSION" | sed -n '1p' | tr -d '\r')"
  [ -n "$expected_sums" ] || {
    printf "%s\n" "VERSION не содержит SUMS_SHA256" >&2
    exit 1
  }
  bootstrap_fetch "$RAW_BASE/SUMS.txt" "$TMP_SUMS" "Warren SUMS.txt" ||
    {
      printf "%s\n" "Не удалось скачать SUMS.txt" >&2
      exit 1
    }
  actual_sums="$(sha256sum "$TMP_SUMS" 2>/dev/null | awk '{print $1}')"
  [ "$actual_sums" = "$expected_sums" ] || {
    printf "%s\n" "SHA256 mismatch для SUMS.txt" >&2
    exit 1
  }
  expected_main="$(awk '$2 == "warren.sh" { print $1; exit }' "$TMP_SUMS")"
  [ -n "$expected_main" ] || {
    printf "%s\n" "SUMS.txt не содержит warren.sh" >&2
    exit 1
  }
else
  expected_main=""
fi

attempt=1
while [ "$attempt" -le 3 ]; do
  bootstrap_fetch "$RAW_BASE/warren.sh" "$TMP_MAIN" "warren.sh" || break
  if [ "${WARREN_SKIP_HASH_CHECK:-0}" = "1" ]; then
    break
  fi
  actual_main="$(sha256sum "$TMP_MAIN" 2>/dev/null | awk '{print $1}')"
  [ "$actual_main" = "$expected_main" ] && break
  rm -f "$TMP_MAIN" 2>/dev/null || true
  attempt=$((attempt + 1))
done

[ -r "$TMP_MAIN" ] || {
  printf "%s\n" "Не удалось скачать и проверить warren.sh" >&2
  exit 1
}

exec sh "$TMP_MAIN" "$@"
