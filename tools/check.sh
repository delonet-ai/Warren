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

# payload/: shipped service scripts, checked with their own interpreter.
for file in "$PROJECT_DIR"/payload/*; do
  case "$(sed -n '1p' "$file")" in
    *bash*) bash -n "$file" ;;
    *python3*) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$file" ;;
    *) sh -n "$file" ;;
  esac
done

# Every lib/ and payload/ file must be listed in the runtime manifest.
MANIFEST="$(sh "$PROJECT_DIR/tools/manifest.sh")"
for file in "$PROJECT_DIR"/lib/*.sh "$PROJECT_DIR"/payload/*; do
  rel="${file#"$PROJECT_DIR"/}"
  printf "%s\n" "$MANIFEST" | grep -qx "$rel" || {
    printf "%s is not in the runtime manifest (warren.sh WARREN_*_LIST)\n" "$rel" >&2
    exit 1
  }
done

sh "$PROJECT_DIR/tools/update-sums.sh" --check
sh "$PROJECT_DIR/tools/gen-index.sh" --check
sh "$PROJECT_DIR/tests/run.sh"
sh "$PROJECT_DIR/tools/build-router-upload.sh" "$CHECK_TMP/router-upload" >/dev/null

test -x "$CHECK_TMP/router-upload/warren.sh"
test -r "$CHECK_TMP/router-upload/lib/versions.sh"
test -r "$CHECK_TMP/router-upload/assets/expand-root.sh"
test -r "$CHECK_TMP/router-upload/payload/warren-tg-bot"
test -r "$CHECK_TMP/router-upload/SUMS.txt"
test -r "$CHECK_TMP/router-upload/luci-app-warren/luasrc/view/warren/index.htm"

printf "\nAll local Warren checks passed.\n"
