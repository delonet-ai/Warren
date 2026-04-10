#!/bin/sh
# Backward-compatible wrapper. Prefer warren.sh.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo ".")"

if [ -r "$SCRIPT_DIR/warren.sh" ]; then
  exec sh "$SCRIPT_DIR/warren.sh" "$@"
fi

TMP_MAIN="/tmp/warren.sh"
wget -qO "$TMP_MAIN" "https://raw.githubusercontent.com/delonet-ai/Warren/main/warren.sh" || {
  printf "%s\n" "Не удалось скачать warren.sh" >&2
  exit 1
}

exec sh "$TMP_MAIN" "$@"
