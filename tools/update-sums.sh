#!/bin/sh
# Regenerate or verify the integrity manifest for Warren runtime payloads.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CHECK_ONLY=0
[ "${1:-}" != "--check" ] || CHECK_ONLY=1

SUMS_TMP="${TMPDIR:-/tmp}/warren-sums.$$"
VERSION_TMP="${TMPDIR:-/tmp}/warren-version.$$"
trap 'rm -f "$SUMS_TMP" "$VERSION_TMP"' EXIT HUP INT TERM

PAYLOADS="
warren.sh
bootstrap.sh
assets/expand-root.sh
assets/sni-candidates.txt
assets/warren-logo.svg
lib/amnezia.sh
lib/amneziawg.sh
lib/basic.sh
lib/common.sh
lib/diagnostics.sh
lib/luci.sh
lib/podkop.sh
lib/qos.sh
lib/remote_admin.sh
lib/sni_checker.sh
lib/state.sh
lib/tg_bot.sh
lib/ui.sh
lib/usb_modem.sh
lib/versions.sh
lib/vps.sh
lib/watchdog.sh
luci-app-warren/Makefile
luci-app-warren/luasrc/controller/warren.lua
luci-app-warren/luasrc/view/warren/index.htm
luci-app-warren/root/usr/libexec/warren/warren-luci-run
luci-app-warren/root/usr/share/luci/menu.d/luci-app-warren.json
luci-app-warren/root/usr/share/rpcd/acl.d/luci-app-warren.json
"

: > "$SUMS_TMP"
for payload in $PAYLOADS; do
  [ -f "$PROJECT_DIR/$payload" ] || {
    printf "Missing manifest payload: %s\n" "$payload" >&2
    exit 1
  }
  payload_sha="$(sha256sum "$PROJECT_DIR/$payload" | awk '{print $1}')"
  printf "%s  %s\n" "$payload_sha" "$payload" >> "$SUMS_TMP"
done

sums_sha="$(sha256sum "$SUMS_TMP" | awk '{print $1}')"
version="$(sed -n '1p' "$PROJECT_DIR/VERSION" | tr -d '\r')"
{
  printf "%s\n" "$version"
  printf "SUMS_SHA256=%s\n" "$sums_sha"
} > "$VERSION_TMP"

if [ "$CHECK_ONLY" = "1" ]; then
  cmp -s "$SUMS_TMP" "$PROJECT_DIR/SUMS.txt" || {
    printf "SUMS.txt is stale; run: sh tools/update-sums.sh\n" >&2
    exit 1
  }
  cmp -s "$VERSION_TMP" "$PROJECT_DIR/VERSION" || {
    printf "VERSION has a stale SUMS_SHA256; run: sh tools/update-sums.sh\n" >&2
    exit 1
  }
  exit 0
fi

mv "$SUMS_TMP" "$PROJECT_DIR/SUMS.txt"
mv "$VERSION_TMP" "$PROJECT_DIR/VERSION"
trap - EXIT HUP INT TERM
printf "Updated SUMS.txt and VERSION (SUMS_SHA256=%s)\n" "$sums_sha"
