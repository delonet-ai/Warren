#!/bin/sh
# Warren settings backup/restore (Mac side): пользовательские списки Podkop.
#
# Снимает с роутера то, что набрано руками и жалко потерять: домены через прокси
# (белый список), домены в обход (секция Exclusion и любые другие секции),
# IP целиком через подкоп (fully_routed_ips), IP в обход (routing_excluded_ips),
# community-листы и типы списков. Кладёт в локальную папку на Mac, умеет вернуть
# обратно на роутер.
#
# На роутере ничего не устанавливает и не запускает своих скриптов:
#   чтение  — `uci export podkop`,
#   запись  — поток команд для `uci -q batch` (данные, не код).
# Перед восстановлением всегда снимается снапшот текущего состояния роутера.
#
# Usage:
#   sh tools/warren-settings.sh save    [--router IP] [--dir DIR] [--name NAME] [--all]
#   sh tools/warren-settings.sh list    [--dir DIR]
#   sh tools/warren-settings.sh show    <snapshot|latest> [--dir DIR]
#   sh tools/warren-settings.sh diff    <snapshot|latest> [--router IP]
#   sh tools/warren-settings.sh restore <snapshot|latest> [--merge] [--dry-run] [--yes] [--no-restart]
#
# Опции:
#   --router IP     адрес роутера (по умолчанию ROUTER_IP из .env или 192.168.1.1 —
#                   тестовый R5S; боевой роутер указывай явно)
#   --port N        SSH-порт роутера (ROUTER_PORT, по умолчанию 22)
#   --user NAME     SSH-пользователь (ROUTER_USER, по умолчанию root)
#   --dir DIR       папка бэкапов (WARREN_SETTINGS_BACKUP_DIR, по умолчанию ~/Warren-backups)
#   --name NAME     суффикс имени снапшота: 20261027-120000-before-reflash
#   --all           дополнительно сохранить uci network/firewall/dhcp/sing-box и warren.conf
#                   (внимание: warren.conf содержит VLESS-ссылку и пароли)
#   --merge         при restore объединить списки снапшота с текущими (ничего не удаляется)
#   --dry-run       только показать, что изменится
#   --yes           не спрашивать подтверждение
#   --no-restart    не перезапускать podkop после восстановления

set -eu
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── defaults from .env (как в tools/test-e2e.sh); флаги важнее ──────────────
env_file="$PROJECT_DIR/.env"
if [ -r "$env_file" ] && [ "${WARREN_SETTINGS_LIB_ONLY:-0}" != "1" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
fi

ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
ROUTER_PORT="${ROUTER_PORT:-22}"
ROUTER_USER="${ROUTER_USER:-root}"
ROUTER_BIND="${ROUTER_BIND:-}"
BACKUP_DIR="${WARREN_SETTINGS_BACKUP_DIR:-$HOME/Warren-backups}"
SNAP_NAME=""
WITH_ALL=0
MERGE_LISTS=0
DRY_RUN=0
ASSUME_YES=0
NO_RESTART=0

TAB="$(printf '\t')"
WS_TMP=""

say() { printf "%s\n" "$*"; }
err() { printf "%s\n" "$*" >&2; }
die() { err "FAIL: $*"; exit 1; }

ws_tmp_dir() {
  if [ -z "$WS_TMP" ]; then
    WS_TMP="${TMPDIR:-/tmp}/warren-settings.$$"
    mkdir -p "$WS_TMP"
  fi
  printf "%s\n" "$WS_TMP"
}

ws_cleanup() {
  [ -z "$WS_TMP" ] || rm -rf "$WS_TMP"
}

# ── router SSH ──────────────────────────────────────────────────────────────
router_ssh() {
  ssh -p "$ROUTER_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ${ROUTER_BIND:+-o} ${ROUTER_BIND:+BindAddress=$ROUTER_BIND} \
      -o LogLevel=ERROR \
      -o ConnectTimeout=8 \
      -o BatchMode=yes \
      "${ROUTER_USER}@${ROUTER_IP}" "$@"
}

router_target() {
  printf "%s@%s:%s\n" "$ROUTER_USER" "$ROUTER_IP" "$ROUTER_PORT"
}

# Локальный source-адрес для SSH: на macOS Wi-Fi и USB-NIC часто в одной /24.
router_autodetect_bind() {
  [ -z "$ROUTER_BIND" ] || return 0
  command -v ifconfig >/dev/null 2>&1 || return 0
  router_net="${ROUTER_IP%.*}."
  ROUTER_BIND="$(ifconfig 2>/dev/null | awk -v net="$router_net" \
    '$1 == "inet" && index($2, net) == 1 { print $2; exit }')"
}

# ── разбор `uci export <pkg>` → TSV: kind \t section \t option \t value ─────
# kind: section (option = тип секции), option, list.
# Безымянные секции получают ref вида @section[0] — их можно читать и сравнивать,
# но создавать заново мы не берёмся (см. warren_settings_restore_commands).
warren_settings_parse_export() {
  awk '
    function unquote(s,   q, p, out) {
      q = "\047"
      if (substr(s, 1, 1) == q && substr(s, length(s), 1) == q) {
        s = substr(s, 2, length(s) - 2)
      } else if (substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") {
        s = substr(s, 2, length(s) - 2)
      }
      # uci export экранирует кавычку как '\'' (4 символа)
      q = "\047\134\047\047"
      out = ""
      while ((p = index(s, q)) > 0) {
        out = out substr(s, 1, p - 1) "\047"
        s = substr(s, p + 4)
      }
      return out s
    }
    /^[[:space:]]*config[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*config[[:space:]]+/, "", line)
      stype = line
      sub(/[[:space:]].*/, "", stype)
      sname = ""
      if (match(line, /[[:space:]]+/)) {
        sname = unquote(substr(line, RSTART + RLENGTH))
      }
      if (sname == "") {
        sref = "@" stype "[" anon[stype] "]"
        anon[stype] = anon[stype] + 1
      } else {
        sref = sname
      }
      printf "section\t%s\t%s\t\n", sref, stype
      next
    }
    /^[[:space:]]*(option|list)[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      kind = line
      sub(/[[:space:]].*/, "", kind)
      rest = line
      sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
      opt = rest
      sub(/[[:space:]].*/, "", opt)
      val = rest
      sub(/^[^[:space:]]+[[:space:]]*/, "", val)
      if (sref == "") next
      printf "%s\t%s\t%s\t%s\n", kind, sref, opt, unquote(val)
    }
  '
}

# Опции, которые относятся к спискам пользователя (а не к каналу/транспорту).
warren_settings_is_list_option() {
  case "${1:-}" in
    *proxy*) return 1 ;;
    source_network_interfaces) return 1 ;;
    user_domains|user_subnets|community_lists) return 0 ;;
    user_domain_list_type|user_subnet_list_type) return 0 ;;
    *_domains|*_subnets|*_ips|*_domain_list|*_subnet_list) return 0 ;;
    *) return 1 ;;
  esac
}

# Русское склонение для счётчиков: 1 элемент / 2 элемента / 5 элементов.
warren_settings_plural_items() {
  _ws_n="${1:-0}"
  case "$((_ws_n % 100))" in
    1[1-9]) printf "элементов\n" ; return 0 ;;
  esac
  case "$((_ws_n % 10))" in
    1)     printf "элемент\n" ;;
    2|3|4) printf "элемента\n" ;;
    *)     printf "элементов\n" ;;
  esac
}

warren_settings_list_filename() {
  _ws_sec="$(printf "%s" "${1:-}" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf "%s.%s.txt\n" "$_ws_sec" "${2:-}"
}

# warren_settings_sections <parsed.tsv> -> ref \t type \t connection_type
warren_settings_sections() {
  awk -F'\t' '
    $1 == "section" { order[++n] = $2; type[$2] = $3; next }
    $1 == "option" && $3 == "connection_type" { conn[$2] = $4 }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\n", order[i], type[order[i]], conn[order[i]] }
  ' "$1"
}

warren_settings_values() {
  # warren_settings_values <parsed.tsv> <section> <option>
  awk -F'\t' -v s="$2" -v o="$3" \
    '($1 == "list" || $1 == "option") && $2 == s && $3 == o { print $4 }' "$1"
}

# warren_settings_write_lists <parsed.tsv> <snapshot dir>
# Пишет lists/index.tsv (file, kind, section, section_type, option, count),
# lists/<section>.<option>.txt (по значению в строке) и sections.tsv.
warren_settings_write_lists() {
  _ws_parsed="$1"
  _ws_snap="$2"
  _ws_lists="$_ws_snap/lists"
  mkdir -p "$_ws_lists"
  : > "$_ws_lists/index.tsv"
  warren_settings_sections "$_ws_parsed" > "$_ws_snap/sections.tsv"

  _ws_keys="$(ws_tmp_dir)/keys.tsv"
  awk -F'\t' '$1 == "list" || $1 == "option" { print $1 "\t" $2 "\t" $3 }' "$_ws_parsed" \
    | sort -u > "$_ws_keys"

  while IFS="$TAB" read -r _ws_kind _ws_sec _ws_opt; do
    [ -n "${_ws_opt:-}" ] || continue
    warren_settings_is_list_option "$_ws_opt" || continue
    _ws_file="$(warren_settings_list_filename "$_ws_sec" "$_ws_opt")"
    warren_settings_values "$_ws_parsed" "$_ws_sec" "$_ws_opt" > "$_ws_lists/$_ws_file"
    _ws_count="$(awk 'END { print NR }' "$_ws_lists/$_ws_file")"
    _ws_type="$(awk -F'\t' -v s="$_ws_sec" '$1 == s { print $2; exit }' "$_ws_snap/sections.tsv")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$_ws_file" "$_ws_kind" "$_ws_sec" "${_ws_type:-section}" "$_ws_opt" "$_ws_count" \
      >> "$_ws_lists/index.tsv"
  done < "$_ws_keys"

  sort -o "$_ws_lists/index.tsv" "$_ws_lists/index.tsv"
}

warren_settings_uci_quote() {
  printf "'%s'" "$(printf "%s" "${1:-}" | sed "s/'/'\\\\''/g")"
}

# warren_settings_restore_commands <snapshot dir> <live parsed.tsv> <replace|merge>
# stdout: команды для `uci -q batch`; stderr: предупреждения.
warren_settings_restore_commands() {
  _ws_snap="$1"
  _ws_live="$2"
  _ws_mode="${3:-replace}"
  _ws_index="$_ws_snap/lists/index.tsv"
  [ -r "$_ws_index" ] || die "В снапшоте нет lists/index.tsv: $_ws_snap"
  _ws_work="$(ws_tmp_dir)"
  _ws_created="$_ws_work/created-sections.txt"
  : > "$_ws_created"

  while IFS="$TAB" read -r _ws_file _ws_kind _ws_sec _ws_stype _ws_opt _ws_count; do
    [ -n "${_ws_opt:-}" ] || continue
    [ -r "$_ws_snap/lists/$_ws_file" ] || continue

    if ! awk -F'\t' -v s="$_ws_sec" '$1 == "section" && $2 == s { found = 1 } END { exit !found }' "$_ws_live"; then
      case "$_ws_sec" in
        @*)
          err "WARN  секция $_ws_sec есть только в снапшоте (безымянная) — пропускаю $_ws_opt"
          continue
          ;;
      esac
      if ! grep -Fqx -- "$_ws_sec" "$_ws_created"; then
        printf "%s\n" "$_ws_sec" >> "$_ws_created"
        printf "set podkop.%s=%s\n" "$_ws_sec" "$_ws_stype"
        _ws_conn="$(awk -F'\t' -v s="$_ws_sec" '$1 == s { print $3; exit }' "$_ws_snap/sections.tsv" 2>/dev/null || true)"
        if [ -n "${_ws_conn:-}" ]; then
          printf "set podkop.%s.connection_type=%s\n" "$_ws_sec" "$(warren_settings_uci_quote "$_ws_conn")"
        fi
      fi
    fi

    if [ "$_ws_kind" = "option" ]; then
      _ws_value="$(awk 'NR == 1 { print }' "$_ws_snap/lists/$_ws_file")"
      [ -n "${_ws_value:-}" ] || continue
      printf "set podkop.%s.%s=%s\n" "$_ws_sec" "$_ws_opt" "$(warren_settings_uci_quote "$_ws_value")"
      continue
    fi

    _ws_values="$_ws_work/values.txt"
    cp "$_ws_snap/lists/$_ws_file" "$_ws_values"
    if [ "$_ws_mode" = "merge" ]; then
      warren_settings_values "$_ws_live" "$_ws_sec" "$_ws_opt" >> "$_ws_values"
    fi

    printf "delete podkop.%s.%s\n" "$_ws_sec" "$_ws_opt"
    _ws_seen="$_ws_work/seen.txt"
    : > "$_ws_seen"
    while IFS= read -r _ws_item; do
      [ -n "$_ws_item" ] || continue
      grep -Fqx -- "$_ws_item" "$_ws_seen" && continue
      printf "%s\n" "$_ws_item" >> "$_ws_seen"
      printf "add_list podkop.%s.%s=%s\n" "$_ws_sec" "$_ws_opt" "$(warren_settings_uci_quote "$_ws_item")"
    done < "$_ws_values"
  done < "$_ws_index"
}

# warren_settings_plan <snapshot dir> <live parsed.tsv> <replace|merge>
# Человеческий diff: что добавится (+) и что исчезнет (-) по каждой опции.
warren_settings_plan() {
  _ws_snap="$1"
  _ws_live="$2"
  _ws_mode="${3:-replace}"
  _ws_index="$_ws_snap/lists/index.tsv"
  [ -r "$_ws_index" ] || die "В снапшоте нет lists/index.tsv: $_ws_snap"
  _ws_work="$(ws_tmp_dir)"
  _ws_changed=0

  while IFS="$TAB" read -r _ws_file _ws_kind _ws_sec _ws_stype _ws_opt _ws_count; do
    [ -n "${_ws_opt:-}" ] || continue
    [ -r "$_ws_snap/lists/$_ws_file" ] || continue

    sort -u "$_ws_snap/lists/$_ws_file" | sed '/^$/d' > "$_ws_work/plan-snap.txt"
    warren_settings_values "$_ws_live" "$_ws_sec" "$_ws_opt" | sort -u | sed '/^$/d' > "$_ws_work/plan-live.txt"

    comm -13 "$_ws_work/plan-live.txt" "$_ws_work/plan-snap.txt" > "$_ws_work/plan-add.txt"
    if [ "$_ws_mode" = "merge" ]; then
      : > "$_ws_work/plan-del.txt"
    else
      comm -23 "$_ws_work/plan-live.txt" "$_ws_work/plan-snap.txt" > "$_ws_work/plan-del.txt"
    fi

    _ws_add="$(awk 'END { print NR }' "$_ws_work/plan-add.txt")"
    _ws_del="$(awk 'END { print NR }' "$_ws_work/plan-del.txt")"
    _ws_live_n="$(awk 'END { print NR }' "$_ws_work/plan-live.txt")"
    _ws_snap_n="$(awk 'END { print NR }' "$_ws_work/plan-snap.txt")"

    if [ "$_ws_kind" = "option" ]; then
      _ws_snap_v="$(awk 'NR == 1 { print }' "$_ws_work/plan-snap.txt")"
      _ws_live_v="$(awk 'NR == 1 { print }' "$_ws_work/plan-live.txt")"
      if [ "$_ws_snap_v" = "$_ws_live_v" ]; then
        printf "  = podkop.%s.%s: %s\n" "$_ws_sec" "$_ws_opt" "$_ws_snap_v"
      else
        _ws_changed=1
        printf "  * podkop.%s.%s: %s -> %s\n" \
          "$_ws_sec" "$_ws_opt" "${_ws_live_v:-(нет)}" "$_ws_snap_v"
      fi
      continue
    fi

    if [ "$_ws_add" = "0" ] && [ "$_ws_del" = "0" ]; then
      printf "  = podkop.%s.%s: %s %s\n" "$_ws_sec" "$_ws_opt" "$_ws_live_n" \
        "$(warren_settings_plural_items "$_ws_live_n")"
      continue
    fi
    _ws_changed=1
    printf "  * podkop.%s.%s: на роутере %s -> станет %s (+%s / -%s)\n" \
      "$_ws_sec" "$_ws_opt" "$_ws_live_n" "$_ws_snap_n" "$_ws_add" "$_ws_del"
    sed -n '1,20p' "$_ws_work/plan-add.txt" | sed 's/^/      + /'
    [ "$_ws_add" -le 20 ] || printf "      + … и ещё %s\n" "$((_ws_add - 20))"
    sed -n '1,20p' "$_ws_work/plan-del.txt" | sed 's/^/      - /'
    [ "$_ws_del" -le 20 ] || printf "      - … и ещё %s\n" "$((_ws_del - 20))"
  done < "$_ws_index"

  [ "$_ws_changed" = "0" ] || return 0
  printf "  Изменений нет: списки на роутере уже совпадают со снапшотом.\n"
}

# ── snapshots ───────────────────────────────────────────────────────────────
warren_settings_resolve_snapshot() {
  _ws_arg="${1:-latest}"
  case "$_ws_arg" in
    /*|./*|../*) printf "%s\n" "${_ws_arg%/}" ; return 0 ;;
  esac
  [ -d "$BACKUP_DIR" ] || die "Папка бэкапов не найдена: $BACKUP_DIR"
  if [ "$_ws_arg" = "latest" ]; then
    if [ -e "$BACKUP_DIR/latest" ]; then
      printf "%s\n" "$(cd "$BACKUP_DIR/latest" && pwd -P)"
      return 0
    fi
    _ws_last=""
    for _ws_dir in "$BACKUP_DIR"/*; do
      [ -d "$_ws_dir" ] || continue
      [ -r "$_ws_dir/lists/index.tsv" ] || continue
      _ws_last="$_ws_dir"
    done
    [ -n "$_ws_last" ] || die "В $BACKUP_DIR нет ни одного снапшота"
    printf "%s\n" "$_ws_last"
    return 0
  fi
  [ -d "$BACKUP_DIR/$_ws_arg" ] || die "Снапшот не найден: $BACKUP_DIR/$_ws_arg"
  printf "%s\n" "$BACKUP_DIR/$_ws_arg"
}

warren_settings_fetch_parsed() {
  # warren_settings_fetch_parsed <export out> <parsed out>
  router_autodetect_bind
  router_ssh 'uci export podkop 2>/dev/null' > "$1" \
    || die "Не удалось прочитать конфиг Podkop с роутера $(router_target)"
  [ -s "$1" ] || die "Роутер $(router_target) вернул пустой конфиг Podkop — Podkop там настроен?"
  warren_settings_parse_export < "$1" > "$2"
}

# warren_settings_do_save <label> [update_latest: 1|0]
warren_settings_do_save() {
  _ws_label="${1:-}"
  _ws_update_latest="${2:-1}"
  mkdir -p "$BACKUP_DIR"
  _ws_stamp="$(date +%Y%m%d-%H%M%S)"
  _ws_snap="$BACKUP_DIR/$_ws_stamp"
  [ -z "$_ws_label" ] || _ws_snap="$_ws_snap-$_ws_label"
  [ ! -e "$_ws_snap" ] || _ws_snap="$_ws_snap-$$"
  mkdir -p "$_ws_snap"

  _ws_parsed="$(ws_tmp_dir)/save-parsed.tsv"
  warren_settings_fetch_parsed "$_ws_snap/podkop.uci" "$_ws_parsed"
  warren_settings_write_lists "$_ws_parsed" "$_ws_snap"

  _ws_meta="$(router_ssh 'uname -srm; sed -n "s/^DISTRIB_RELEASE=//p" /etc/openwrt_release 2>/dev/null; (apk list -I podkop 2>/dev/null || opkg list-installed podkop 2>/dev/null) | head -n 1' 2>/dev/null || true)"

  {
    printf "# Warren settings snapshot\n"
    printf "date=%s\n" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf "router=%s\n" "$(router_target)"
    printf "%s\n" "$_ws_meta" | awk 'NF { printf "router_info=%s\n", $0 }'
    printf "\n# секции podkop (ref, type, connection_type)\n"
    sed 's/^/section=/' "$_ws_snap/sections.tsv"
    printf "\n# списки (файл, опция, элементов)\n"
    awk -F'\t' '{ printf "list=%s\t%s.%s\t%s\n", $1, $3, $5, $6 }' "$_ws_snap/lists/index.tsv"
  } > "$_ws_snap/manifest.txt"

  if [ "$WITH_ALL" = "1" ]; then
    mkdir -p "$_ws_snap/extra"
    for _ws_pkg in network firewall dhcp sing-box; do
      router_ssh "uci export $_ws_pkg 2>/dev/null" > "$_ws_snap/extra/$_ws_pkg.uci" 2>/dev/null || true
      [ -s "$_ws_snap/extra/$_ws_pkg.uci" ] || rm -f "$_ws_snap/extra/$_ws_pkg.uci"
    done
    router_ssh 'cat /etc/warren/warren.conf 2>/dev/null' > "$_ws_snap/extra/warren.conf" 2>/dev/null || true
    if [ -s "$_ws_snap/extra/warren.conf" ]; then
      chmod 600 "$_ws_snap/extra/warren.conf" 2>/dev/null || true
      say "WARN  extra/warren.conf содержит VLESS-ссылку и пароли — не выкладывай снапшот в git."
    else
      rm -f "$_ws_snap/extra/warren.conf"
    fi
  fi

  if [ "$_ws_update_latest" = "1" ]; then
    rm -f "$BACKUP_DIR/latest"
    ln -s "$_ws_snap" "$BACKUP_DIR/latest" 2>/dev/null || true
  fi

  say "Снапшот сохранён: $_ws_snap"
  awk -F'\t' '{ printf "  %s.%s: %s\n", $3, $5, $6 }' "$_ws_snap/lists/index.tsv"
  printf "%s\n" "$_ws_snap"
}

# ── команды ─────────────────────────────────────────────────────────────────
cmd_save() {
  _ws_out="$(warren_settings_do_save "$SNAP_NAME")"
  _ws_snap="$(printf "%s\n" "$_ws_out" | tail -n 1)"
  printf "%s\n" "$_ws_out" | sed '$d'
  say ""
  say "Списки лежат текстом в $_ws_snap/lists/ — можно править руками и восстанавливать."
}

cmd_list() {
  _ws_any=0
  say "Бэкапы в $BACKUP_DIR:"
  for _ws_dir in "$BACKUP_DIR"/*; do
    [ -d "$_ws_dir" ] || continue
    [ ! -L "$_ws_dir" ] || continue
    [ -r "$_ws_dir/lists/index.tsv" ] || continue
    _ws_any=1
    _ws_items="$(awk -F'\t' '{ total += $6 } END { print total + 0 }' "$_ws_dir/lists/index.tsv")"
    _ws_router="$(sed -n 's/^router=//p' "$_ws_dir/manifest.txt" 2>/dev/null | head -n 1)"
    printf "  %-34s %5s %-10s %s\n" "$(basename "$_ws_dir")" "$_ws_items" \
      "$(warren_settings_plural_items "$_ws_items")" "${_ws_router:-?}"
  done
  [ "$_ws_any" = "1" ] || say "  (пусто)"
}

cmd_show() {
  _ws_snap="$(warren_settings_resolve_snapshot "${1:-latest}")"
  say "Снапшот: $_ws_snap"
  [ ! -r "$_ws_snap/manifest.txt" ] || sed 's/^/  /' "$_ws_snap/manifest.txt"
}

cmd_diff() {
  _ws_snap="$(warren_settings_resolve_snapshot "${1:-latest}")"
  _ws_live="$(ws_tmp_dir)/live-parsed.tsv"
  warren_settings_fetch_parsed "$(ws_tmp_dir)/live.uci" "$_ws_live"
  _ws_mode="replace"
  [ "$MERGE_LISTS" = "0" ] || _ws_mode="merge"
  say "Снапшот: $_ws_snap"
  say "Роутер:  $(router_target)"
  warren_settings_plan "$_ws_snap" "$_ws_live" "$_ws_mode"
}

cmd_restore() {
  _ws_snap="$(warren_settings_resolve_snapshot "${1:-latest}")"
  _ws_mode="replace"
  [ "$MERGE_LISTS" = "0" ] || _ws_mode="merge"

  _ws_live="$(ws_tmp_dir)/live-parsed.tsv"
  warren_settings_fetch_parsed "$(ws_tmp_dir)/live.uci" "$_ws_live"

  say "Снапшот: $_ws_snap"
  say "Роутер:  $(router_target)"
  say "Режим:   $([ "$_ws_mode" = "merge" ] && printf "объединение (ничего не удаляется)" || printf "замена списков из снапшота")"
  say ""
  say "Что изменится:"
  warren_settings_plan "$_ws_snap" "$_ws_live" "$_ws_mode"

  _ws_cmds="$(ws_tmp_dir)/restore.uci"
  warren_settings_restore_commands "$_ws_snap" "$_ws_live" "$_ws_mode" > "$_ws_cmds"
  if [ ! -s "$_ws_cmds" ]; then
    say ""
    say "Нечего применять."
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    say ""
    say "--dry-run: команды для uci batch ($(awk 'END { print NR }' "$_ws_cmds")):"
    sed 's/^/  /' "$_ws_cmds"
    return 0
  fi

  if [ "$ASSUME_YES" != "1" ]; then
    printf "Применить на %s? [y/N]: " "$(router_target)"
    read -r _ws_answer || _ws_answer=""
    case "$_ws_answer" in
      y|Y|yes|YES|д|Д|да|ДА) ;;
      *) say "Отменено."; return 0 ;;
    esac
  fi

  say ""
  # Снимок текущего состояния — на случай «верни как было»; latest не трогаем.
  _ws_backup="$(warren_settings_do_save "pre-restore" 0 | tail -n 1)"
  say "Текущее состояние роутера сохранено: $_ws_backup"
  say "Откат: sh tools/warren-settings.sh restore $(basename "$_ws_backup")"

  router_ssh 'cat > /tmp/warren-settings-restore.uci && uci -q batch < /tmp/warren-settings-restore.uci && uci commit podkop && rm -f /tmp/warren-settings-restore.uci' \
    < "$_ws_cmds" || die "Не удалось применить списки на роутере (конфиг не закоммичен)"
  say "Списки применены и закоммичены."

  if [ "$NO_RESTART" = "1" ]; then
    say "WARN  podkop не перезапущен (--no-restart): изменения вступят в силу после restart."
  else
    router_ssh '/etc/init.d/podkop restart >/dev/null 2>&1 || service podkop restart >/dev/null 2>&1' \
      || say "WARN  не удалось перезапустить podkop — сделай это вручную."
    say "Podkop перезапущен."
  fi

  _ws_after="$(ws_tmp_dir)/after-parsed.tsv"
  warren_settings_fetch_parsed "$(ws_tmp_dir)/after.uci" "$_ws_after"
  _ws_check="$(ws_tmp_dir)/after-plan.txt"
  warren_settings_plan "$_ws_snap" "$_ws_after" "$_ws_mode" > "$_ws_check"
  say ""
  if grep -q "^  \* " "$_ws_check"; then
    say "WARN  роутер всё ещё отличается от снапшота:"
    grep "^  \* " "$_ws_check"
  else
    say "Проверка: списки на роутере совпадают со снапшотом."
  fi
}

usage() {
  awk '/^# Usage:/ { show = 1 } show && !/^#/ { exit } show { sub(/^# ?/, ""); print }' "$0"
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 1; }
  _ws_cmd="$1"
  shift

  _ws_arg=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --router)     ROUTER_IP="${2:-}";   shift 2 ;;
      --port)       ROUTER_PORT="${2:-22}"; shift 2 ;;
      --user)       ROUTER_USER="${2:-root}"; shift 2 ;;
      --bind)       ROUTER_BIND="${2:-}"; shift 2 ;;
      --dir)        BACKUP_DIR="${2:-}";  shift 2 ;;
      --name)       SNAP_NAME="${2:-}";   shift 2 ;;
      --all)        WITH_ALL=1;           shift 1 ;;
      --merge)      MERGE_LISTS=1;        shift 1 ;;
      --dry-run)    DRY_RUN=1;            shift 1 ;;
      --yes|-y)     ASSUME_YES=1;         shift 1 ;;
      --no-restart) NO_RESTART=1;         shift 1 ;;
      -h|--help)    usage; exit 0 ;;
      -*)           die "Неизвестная опция: $1" ;;
      *)            [ -n "$_ws_arg" ] && die "Лишний аргумент: $1"; _ws_arg="$1"; shift 1 ;;
    esac
  done

  trap ws_cleanup EXIT HUP INT TERM

  case "$_ws_cmd" in
    save)    cmd_save ;;
    list|ls) cmd_list ;;
    show)    cmd_show "$_ws_arg" ;;
    diff)    cmd_diff "$_ws_arg" ;;
    restore) cmd_restore "$_ws_arg" ;;
    help|-h|--help) usage ;;
    *)       die "Неизвестная команда: $_ws_cmd (save|list|show|diff|restore)" ;;
  esac
}

[ "${WARREN_SETTINGS_LIB_ONLY:-0}" = "1" ] || main "$@"
