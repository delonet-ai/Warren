#!/bin/sh
# Run all checks that do not require an OpenWrt router or network access.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CHECK_TMP="${TMPDIR:-/tmp}/warren-check.$$"

mkdir -p "$CHECK_TMP"
trap 'rm -rf "$CHECK_TMP"' EXIT HUP INT TERM

for file in \
  "$PROJECT_DIR/warren.sh" \
  "$PROJECT_DIR/bootstrap.sh" \
  "$PROJECT_DIR/assets/expand-root.sh" \
  "$PROJECT_DIR"/lib/*.sh \
  "$PROJECT_DIR"/tools/*.sh \
  "$PROJECT_DIR"/tools/remote-admin/*.sh \
  "$PROJECT_DIR"/tests/*.sh
do
  sh -n "$file"
done

sh "$PROJECT_DIR/tools/update-sums.sh" --check
sh "$PROJECT_DIR/tools/gen-index.sh" --check
sh "$PROJECT_DIR/tests/run.sh"
sh "$PROJECT_DIR/tools/build-router-upload.sh" "$CHECK_TMP/router-upload" >/dev/null

test -x "$CHECK_TMP/router-upload/warren.sh"
test -r "$CHECK_TMP/router-upload/lib/versions.sh"
test -r "$CHECK_TMP/router-upload/assets/expand-root.sh"
test -r "$CHECK_TMP/router-upload/SUMS.txt"
test -r "$CHECK_TMP/router-upload/luci-app-warren/luasrc/view/warren/index.htm"

printf "\nAll local Warren checks passed.\n"
