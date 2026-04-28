module("luci.controller.warren", package.seeall)

function index()
  entry({"admin", "services", "warren"}, call("action_index"), _("Warren"), 60).dependent = true
  entry({"admin", "services", "warren", "run"}, post("action_run")).leaf = true
end

local function shellquote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
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

local function first_match(text, pattern)
  if not text then return "" end
  return trim(text:match(pattern) or "")
end

local function basename(path)
  return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function list_reports()
  local reports = {}
  local p = io.popen("find /etc/vps/reports -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort")
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
  local state = tonumber(trim(read_file("/etc/warren.state") or "0")) or 0
  return state
end

local function read_conf_mode()
  local conf = read_file("/etc/warren.conf") or ""
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
      { key = "preflight", title = "Preflight", start = 0, done = 30 },
      { key = "packages", title = "Базовые пакеты", start = 30, done = 40 },
      { key = "expand_root", title = "Подготовка expand-root", start = 40, done = 50 },
      { key = "post_reboot", title = "Post-reboot setup", start = 50, done = 75 }
    }
  else
    steps = {
      { key = "preflight", title = "Preflight", start = 0, done = 30 },
      { key = "packages", title = "Базовые пакеты", start = 30, done = 40 },
      { key = "expand_root", title = "Подготовка expand-root", start = 40, done = 50 },
      { key = "post_reboot", title = "Post-reboot setup", start = 50, done = 75 },
      { key = "podkop_install", title = "Установка Podkop", start = 75, done = 80 },
      { key = "podkop_config", title = "Настройка Podkop", start = 80, done = 90 },
      { key = "awg_install", title = "Установка AWG", start = 90, done = 100 },
      { key = "awg_setup", title = "Настройка AWG", start = 100, done = 110 },
      { key = "clients", title = "Клиенты и QR", start = 110, done = 120 }
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
  local target = (tile_mode == "basic") and 75 or 120
  local resume = conf_mode == tile_mode and state > 0 and state < target
  local failed = resume and not (job and job.running) and job and job.mode == tile_mode and job.exit_code ~= "" and job.exit_code ~= "0"

  return {
    mode = tile_mode,
    state = state,
    resume = resume,
    button_label = resume and ("Продолжить " .. (tile_mode == "basic" and "Basic setup" or "Auto")) or ("Запустить " .. (tile_mode == "basic" and "Basic setup" or "Auto")),
    steps = step_list_with_status(state, conf_mode, tile_mode, failed),
    failed = failed
  }
end

local function write_form_env()
  local http = require "luci.http"
  local allowed = {
    VPS_HOST = "vps_host",
    VPS_SSH_PORT = "vps_ssh_port",
    VPS_ROOT_PASSWORD = "vps_root_password",
    TG_BOT_TOKEN = "tg_bot_token",
    TG_BOT_CHAT_ID = "tg_chat_id"
  }
  local lines = {}
  for env_name, form_name in pairs(allowed) do
    local value = http.formvalue(form_name)
    if value and value ~= "" then
      lines[#lines + 1] = env_name .. "=" .. shellquote(value)
    end
  end
  write_file("/tmp/warren-luci-job.env", table.concat(lines, "\n") .. "\n", "600")
end

function action_index()
  local tpl = require "luci.template"
  local job = job_status()
  local state = read_state()
  local conf_mode = read_conf_mode()
  tpl.render("warren/index", {
    reports = list_reports(),
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
    write_form_env()
    os.execute("/usr/libexec/warren/warren-luci-run " .. shellquote(mode) .. " >/dev/null 2>&1")
  end
  http.redirect(luci.dispatcher.build_url("admin", "services", "warren"))
end
