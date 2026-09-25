#!/bin/sh
# Print every runtime file Warren ships, one repo-relative path per line.
# Source of truth: WARREN_LIB_LIST / WARREN_ASSET_LIST / WARREN_PAYLOAD_LIST in warren.sh.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

manifest_list() {
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$PROJECT_DIR/warren.sh" | sed -n '1p'
}

libs="$(manifest_list WARREN_LIB_LIST)"
assets="$(manifest_list WARREN_ASSET_LIST)"
payloads="$(manifest_list WARREN_PAYLOAD_LIST)"
[ -n "$libs" ] && [ -n "$assets" ] && [ -n "$payloads" ] || {
  printf "%s\n" "warren.sh: WARREN_LIB_LIST/WARREN_ASSET_LIST/WARREN_PAYLOAD_LIST not found" >&2
  exit 1
}

printf "%s\n" warren.sh bootstrap.sh
for f in $assets; do printf "assets/%s\n" "$f"; done
for f in $libs; do printf "lib/%s\n" "$f"; done
for f in $payloads; do printf "payload/%s\n" "$f"; done
cat <<'LUCI'
luci-app-warren/Makefile
luci-app-warren/luasrc/controller/warren.lua
luci-app-warren/luasrc/view/warren/index.htm
luci-app-warren/root/usr/libexec/warren/warren-luci-run
luci-app-warren/root/usr/share/luci/menu.d/luci-app-warren.json
luci-app-warren/root/usr/share/rpcd/acl.d/luci-app-warren.json
LUCI
