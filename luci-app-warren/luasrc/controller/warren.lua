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
  if pid ~= "" then
    running = os.execute("kill -0 " .. shellquote(pid) .. " >/dev/null 2>&1") == 0
  end
  return {
    pid = pid,
    running = running,
    log = log,
    mode = trim(log:match("=== Warren LuCI job:%s*([^=]+)===") or "")
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
  tpl.render("warren/index", {
    reports = list_reports(),
    job = job_status()
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
