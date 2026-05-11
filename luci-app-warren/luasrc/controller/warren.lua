module("luci.controller.warren", package.seeall)

local WARREN_ETC_DIR = "/etc/warren"
local LEGACY_WARREN_ETC_DIR = "/etc"

local function existing_path(primary, legacy)
  local f = io.open(primary, "r")
  if f then
    f:close()
    return primary
  end
  return legacy
end

local function reports_dir()
  local primary = WARREN_ETC_DIR .. "/vps/reports"
  local p = io.popen("[ -d " .. primary .. " ] && echo yes")
  if p then
    local out = (p:read("*a") or ""):gsub("%s+$", "")
    p:close()
    if out == "yes" then
      return primary
    end
  end
  return LEGACY_WARREN_ETC_DIR .. "/vps/reports"
end

function index()
  entry({"admin", "services", "warren"}, call("action_index"), _("Warren"), 60).dependent = true
  entry({"admin", "services", "warren", "run"}, post("action_run")).leaf = true
end

local function shellquote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function trim(value)
  return ((value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function read_conf_table()
  local conf_path = existing_path(WARREN_ETC_DIR .. "/warren.conf", LEGACY_WARREN_ETC_DIR .. "/warren.conf")
  local raw = read_file(conf_path) or ""
  local conf = {}
  for key, value in raw:gmatch("([A-Z_]+)='([^']*)'") do
    conf[key] = value
  end
  return conf
end

local function write_file(path, data, mode)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(data or "")
  f:close()
  if mode then
    os.execute("chmod " .. mode .. " " .. shellquote(path) .. " >/dev/null 2>&1")
  end
  return true
end

local function proxy_link_supported(value)
  value = tostring(value or "")
  return value:match("^vless://") or value:match("^ss://") or value:match("^trojan://")
    or value:match("^socks4://") or value:match("^socks5://")
    or value:match("^hy2://") or value:match("^hysteria2://")
end

local function first_match(text, pattern)
  if not text then return "" end
  return trim(text:match(pattern) or "")
end

local function basename(path)
  return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function list_reports()
  local reports = {}
  local p = io.popen("find " .. shellquote(reports_dir()) .. " -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort")
  if p then
    for path in p:lines() do
      local text = read_file(path) or ""
      reports[#reports + 1] = {
        path = path,
        name = basename(path):gsub("%.txt$", ""),
        host = first_match(text, "\nHost:%s*([^\n]+)") or first_match(text, "^Host:%s*([^\n]+)"),
        ssh_port = first_match(text, "\nSSH port:%s*([^\n]+)") or first_match(text, "^SSH port:%s*([^\n]+)"),
        root_password = first_match(text, "\nSSH root password:%s*([^\n]+)") or first_match(text, "^SSH root password:%s*([^\n]+)"),
        os = first_match(text, "\nOS:%s*([^\n]+)") or first_match(text, "^OS:%s*([^\n]+)"),
        ui_url = first_match(text, "\n3x%-ui URL:%s*([^\n]+)") or first_match(text, "^3x%-ui URL:%s*([^\n]+)"),
        ui_username = first_match(text, "\n3x%-ui username:%s*([^\n]+)") or first_match(text, "^3x%-ui username:%s*([^\n]+)"),
        ui_password = first_match(text, "\n3x%-ui password:%s*([^\n]+)") or first_match(text, "^3x%-ui password:%s*([^\n]+)"),
        vless = first_match(text, "\nVLESS inbound link:%s*([^\n]+)") or first_match(text, "^VLESS inbound link:%s*([^\n]+)"),
        client_uuid = first_match(text, "\nClient uuid:%s*([^\n]+)") or first_match(text, "^Client uuid:%s*([^\n]+)")
      }
    end
    p:close()
  end
  return reports
end

local function report_proxy_link(path)
  local text = read_file(path) or ""
  return first_match(text, "\nVLESS inbound link:%s*([^\n]+)") or first_match(text, "^VLESS inbound link:%s*([^\n]+)")
end

local function link_in_channels(link, channels)
  if link == "" or not channels then return false end
  for _, channel in ipairs(channels) do
    if channel == link then
      return true
    end
  end
  return false
end

local function shell_read(command)
  local p = io.popen(command .. " 2>/dev/null")
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return trim(out)
end

local function podkop_mode_label(raw_mode)
  if raw_mode == "urltest" then return "URLTest (несколько каналов)" end
  if raw_mode == "url" then return "Одиночный VLESS" end
  if raw_mode == "selector" then return "Selector" end
  if raw_mode == "" then return "Не задан" end
  return raw_mode
end

local function podkop_status()
  local raw_mode = shell_read("uci -q get podkop.main.proxy_config_type")
  local channels = {}
  local cmd

  if raw_mode == "urltest" then
    cmd = "uci -q get podkop.main.urltest_proxy_links | tr ' ' '\\n'"
  else
    cmd = "uci -q get podkop.main.proxy_string"
  end

  local p = io.popen(cmd .. " 2>/dev/null")
  if p then
    for line in p:lines() do
      line = trim(line)
      if line ~= "" then
        channels[#channels + 1] = line
      end
    end
    p:close()
  end

  return {
    raw_mode = raw_mode,
    mode_label = podkop_mode_label(raw_mode),
    channels = channels
  }
end

local function annotate_reports_for_podkop(reports, podkop)
  local available_backup_count = 0
  for _, report in ipairs(reports or {}) do
    report.in_podkop = link_in_channels(report.vless or "", podkop and podkop.channels or {})
    if report.vless ~= "" and not report.in_podkop then
      available_backup_count = available_backup_count + 1
    end
  end
  return available_backup_count
end

local function job_status()
  local pid = trim(read_file("/tmp/warren-luci-job.pid") or "")
  local running = false
  local log = read_file("/tmp/warren-luci-job.log") or ""
  local exit_code = first_match(log, "\n=== exit code:%s*([^\n=]+)") or first_match(log, "^=== exit code:%s*([^\n=]+)")
  if pid ~= "" then
    running = os.execute("kill -0 " .. shellquote(pid) .. " >/dev/null 2>&1") == 0
  end
  return {
    pid = pid,
    running = running,
    log = log,
    mode = trim(log:match("=== Warren LuCI job:%s*([^=]+)===") or ""),
    exit_code = trim(exit_code or "")
  }
end

local function read_state()
  local state_path = existing_path(WARREN_ETC_DIR .. "/warren.state", LEGACY_WARREN_ETC_DIR .. "/warren.state")
  local state = tonumber(trim(read_file(state_path) or "0")) or 0
  return state
end

local function read_conf_mode()
  local conf_path = existing_path(WARREN_ETC_DIR .. "/warren.conf", LEGACY_WARREN_ETC_DIR .. "/warren.conf")
  local conf = read_file(conf_path) or ""
  return first_match(conf, "\nMODE='([^']*)'") or first_match(conf, "^MODE='([^']*)'") or ""
end

local function stage_status(state, mode, tile_mode, step)
  local status = ""
  if state >= step.done then
    status = "done"
  elseif mode == tile_mode and state >= step.start and state < step.done then
    status = "active"
  end
  return status
end

local function step_list_with_status(state, mode, tile_mode, failed)
  local steps
  if tile_mode == "basic" then
    steps = {
      { key = "openwrt", title = "Версия OpenWrt", start = 0, done = 10 },
      { key = "internet", title = "Интернет", start = 10, done = 20 },
      { key = "time", title = "Время и TLS", start = 20, done = 30 },
      { key = "packages", title = "Базовые пакеты", start = 30, done = 40 },
      { key = "overlay", title = "Проверка overlay", start = 40, done = 45 },
      { key = "expand_prepare", title = "Подготовка expand-root", start = 45, done = 50 },
      { key = "expand_reboot", title = "Resize и ребут", start = 50, done = 60 },
      { key = "post_packages", title = "Пакеты после ребута", start = 60, done = 70 },
      { key = "post_space", title = "Финальная проверка места", start = 70, done = 75 }
    }
  else
    steps = {
      { key = "preflight", title = "Preflight", start = 0, done = 30 },
      { key = "packages", title = "Базовые пакеты", start = 30, done = 40 },
      { key = "expand_root", title = "Проверка места / подготовка expand-root", start = 40, done = 50 },
      { key = "post_reboot", title = "Post-reboot setup", start = 50, done = 75 },
      { key = "warren_ui", title = "Установка UI Warren", start = 75, done = 80 },
      { key = "proxy_source", title = "Источник proxy-конфига", start = 80, done = 85 },
      { key = "podkop_install", title = "Установка Podkop", start = 85, done = 90 },
      { key = "podkop_config", title = "Настройка Podkop", start = 90, done = 95 },
      { key = "final_summary", title = "Финальный отчёт", start = 95, done = 100 }
    }
  end

  for _, step in ipairs(steps) do
    step.status = stage_status(state, mode, tile_mode, step)
  end

  if failed and mode == tile_mode then
    for _, step in ipairs(steps) do
      if step.status == "active" then
        step.status = "fail"
        break
      end
    end
  end

  return steps
end

local function tile_state(tile_mode, state, conf_mode, job)
  local target = (tile_mode == "basic") and 75 or 100
  local resume = conf_mode == tile_mode and state > 0 and state < target
  local failed = resume and not (job and job.running) and job and job.mode == tile_mode and job.exit_code ~= "" and job.exit_code ~= "0"

  return {
    mode = tile_mode,
    state = state,
    resume = resume,
    button_label = resume
      and (tile_mode == "basic" and "Продолжить Базовые настройки" or "Продолжить Полный авторежим")
      or (tile_mode == "basic" and "Запустить Базовые настройки" or "Запустить Полный авторежим"),
    steps = step_list_with_status(state, conf_mode, tile_mode, failed),
    failed = failed
  }
end

local function write_form_env()
  local http = require "luci.http"
  local allowed = {
    AUTO_VPS_SOURCE = "auto_vps_source",
    SELECTED_VPS_REPORT = "selected_vps_report",
    VLESS = "vless",
    BROWSER_EPOCH = "browser_epoch",
    VPS_HOST = "vps_host",
    VPS_SSH_PORT = "vps_ssh_port",
    VPS_ROOT_PASSWORD = "vps_root_password",
    TG_BOT_TOKEN = "tg_bot_token",
    TG_BOT_CHAT_ID = "tg_chat_id"
  }
  local lines = {"WARREN_LUCI_FORM=1"}
  for env_name, form_name in pairs(allowed) do
    local value = http.formvalue(form_name)
    lines[#lines + 1] = env_name .. "=" .. shellquote(value or "")
  end
  write_file("/tmp/warren-luci-job.env", table.concat(lines, "\n") .. "\n", "600")
end

local function write_luci_error_log(mode, message)
  local log = table.concat({
    "=== Warren LuCI job: " .. tostring(mode or "") .. " ===",
    os.date(),
    "",
    "FAIL  " .. tostring(message or "Ошибка формы Warren"),
    "",
    "=== exit code: 2 ===",
    os.date(),
    ""
  }, "\n")
  write_file("/tmp/warren-luci-job.log", log, "600")
  write_file("/tmp/warren-luci-job.pid", "", "600")
end

local function validate_run_form(mode)
  local http = require "luci.http"
  local source = trim(http.formvalue("auto_vps_source") or "")
  local selected_report = trim(http.formvalue("selected_vps_report") or "")
  local vless = trim(http.formvalue("vless") or "")
  local vps_host = trim(http.formvalue("vps_host") or "")
  local vps_ssh_port = trim(http.formvalue("vps_ssh_port") or "")
  local vps_root_password = trim(http.formvalue("vps_root_password") or "")

  if mode == "podkop_setup" or mode == "podkop_backup" then
    if selected_report ~= "" then
      if not read_file(selected_report) then
        return false, "Выбранный VPS-отчёт не найден: " .. selected_report
      end
      local report_link = report_proxy_link(selected_report)
      if not proxy_link_supported(report_link) then
        return false, "В выбранном VPS-отчёте нет поддерживаемой proxy-ссылки."
      end
      if mode == "podkop_backup" and link_in_channels(report_link, podkop_status().channels) then
        return false, "Этот VPS-отчёт уже добавлен в текущие каналы Podkop."
      end
      return true
    end
    if vless == "" then
      return false, "Для Podkop выбери VPS-отчёт Warren или вставь proxy-ссылку."
    end
    if not proxy_link_supported(vless) then
      return false, "Proxy-ссылка должна начинаться с vless://, ss://, trojan://, socks4://, socks5://, hy2:// или hysteria2://."
    end
    return true
  end

  if mode ~= "auto" then
    return true
  end

  if source == "new_vps" then
    if vps_host == "" then return false, "Для Auto/new_vps укажи IP адрес VPS." end
    if vps_ssh_port == "" then return false, "Для Auto/new_vps укажи SSH порт VPS." end
    if vps_root_password == "" then return false, "Для Auto/new_vps укажи root пароль VPS." end
    return true
  end

  if source == "report" then
    if selected_report == "" then return false, "Для Auto/report выбери VPS-отчёт Warren." end
    if not read_file(selected_report) then return false, "Выбранный VPS-отчёт не найден: " .. selected_report end
    if not proxy_link_supported(report_proxy_link(selected_report)) then return false, "В выбранном VPS-отчёте нет поддерживаемой proxy-ссылки." end
    return true
  end

  if source == "link" then
    if vless == "" then return false, "Для Auto/link вставь proxy-ссылку." end
    if not proxy_link_supported(vless) then return false, "Proxy-ссылка должна начинаться с vless://, ss://, trojan://, socks4://, socks5://, hy2:// или hysteria2://." end
    return true
  end

  return false, "Выбери источник proxy-конфига для Auto: new_vps, report или link."
end

function action_index()
  local tpl = require "luci.template"
  local job = job_status()
  local state = read_state()
  local conf_mode = read_conf_mode()
  local conf = read_conf_table()
  local podkop = podkop_status()
  local reports = list_reports()
  local backup_report_count = annotate_reports_for_podkop(reports, podkop)
  tpl.render("warren/index", {
    conf = conf,
    reports = reports,
    podkop = podkop,
    backup_report_count = backup_report_count,
    job = job,
    warren_state = state,
    warren_mode = conf_mode,
    basic_tile = tile_state("basic", state, conf_mode, job),
    auto_tile = tile_state("auto", state, conf_mode, job)
  })
end

function action_run()
  local http = require "luci.http"
  local mode = http.formvalue("mode") or ""
  if mode:match("^[A-Za-z0-9_-]+$") then
    local ok, err = validate_run_form(mode)
    if ok then
      write_form_env()
      os.execute("/usr/libexec/warren/warren-luci-run " .. shellquote(mode) .. " >/dev/null 2>&1")
    else
      write_luci_error_log(mode, err)
    end
  end
  http.redirect(luci.dispatcher.build_url("admin", "services", "warren"))
end
