#!/bin/sh
# Build a disposable router-upload directory from the current source tree.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="$(sed -n '1p' "$PROJECT_DIR/VERSION" | tr -d '\r')"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist/warren-router-upload-${VERSION}}"

case "$OUTPUT_DIR" in
  /|""|"$PROJECT_DIR")
    printf "Refusing unsafe output directory: %s\n" "$OUTPUT_DIR" >&2
    exit 1
    ;;
esac

if [ -e "$OUTPUT_DIR" ]; then
  printf "Output already exists: %s\n" "$OUTPUT_DIR" >&2
  printf "Choose a new path or remove the old generated bundle first.\n" >&2
  exit 1
fi

sh "$SCRIPT_DIR/manifest.sh" | while IFS= read -r rel; do
  mkdir -p "$OUTPUT_DIR/$(dirname "$rel")"
  cp "$PROJECT_DIR/$rel" "$OUTPUT_DIR/$rel"
done
cp "$PROJECT_DIR/VERSION" "$PROJECT_DIR/SUMS.txt" "$OUTPUT_DIR/"

find "$OUTPUT_DIR" -type d -exec chmod 755 {} \;
find "$OUTPUT_DIR" -type f -exec chmod 644 {} \;
chmod 755 \
  "$OUTPUT_DIR/warren.sh" \
  "$OUTPUT_DIR/bootstrap.sh" \
  "$OUTPUT_DIR"/lib/*.sh \
  "$OUTPUT_DIR/luci-app-warren/root/usr/libexec/warren/warren-luci-run"

printf "Built Warren router upload bundle: %s\n" "$OUTPUT_DIR"
