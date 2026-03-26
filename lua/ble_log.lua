local socket_ok, socket = pcall(require, "socket")

local M = {}

local cfg = {
  file_enabled = true,
  max_file_size = 512 * 1024,
  max_files = 3,
  server_enabled = true,
  port = 4400,
  log_name = "ble.log",
}

local buffer = {}
local followers = {}
local clients = {}
local server = nil
local start_time = nil
local rotation_count = 0
local client_buffers = {}
local server_failed = false
M.server_state = "pending"

function M.configure(opts)
  if not opts then return end
  for k, v in pairs(opts) do
    if cfg[k] ~= nil then
      cfg[k] = v
    end
  end
end

local function timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%S")
end

function M.write(category, message)
  if not cfg.file_enabled and not cfg.server_enabled then return end
  local line = timestamp() .. " [" .. (category or "?") .. "] " .. tostring(message or "")
  buffer[#buffer + 1] = line
end

local function log_path(index)
  if index == 0 then
    return cfg.log_name
  end
  return cfg.log_name .. "." .. index
end

local function file_size(path)
  local info = love.filesystem.getInfo(path)
  if info then return info.size or 0 end
  return 0
end

local function rotate()
  local last = log_path(cfg.max_files - 1)
  if love.filesystem.getInfo(last) then
    love.filesystem.remove(last)
  end

  for i = cfg.max_files - 2, 0, -1 do
    local src = log_path(i)
    local dst = log_path(i + 1)
    if love.filesystem.getInfo(src) then
      local data = love.filesystem.read(src)
      if data then
        love.filesystem.write(dst, data)
        love.filesystem.remove(src)
      end
    end
  end

  rotation_count = rotation_count + 1
end

local function send_to_client(client, data)
  local ok, err = pcall(function() client:send(data) end)
  if not ok then
    followers[client] = nil
    clients[client] = nil
    client_buffers[client] = nil
    pcall(function() client:close() end)
  end
end

local function flush_buffer()
  if #buffer == 0 then return end

  local chunk = table.concat(buffer, "\n") .. "\n"

  if cfg.file_enabled then
    local path = log_path(0)
    love.filesystem.append(path, chunk)

    if file_size(path) >= cfg.max_file_size then
      rotate()
    end
  end

  if cfg.server_enabled then
    for client, _ in pairs(followers) do
      send_to_client(client, chunk)
    end
  end

  buffer = {}
end

local function read_all_lines()
  local lines = {}
  for i = cfg.max_files - 1, 0, -1 do
    local path = log_path(i)
    local data = love.filesystem.read(path)
    if data then
      for line in data:gmatch("[^\n]+") do
        lines[#lines + 1] = line
      end
    end
  end
  return lines
end

local function cmd_tail(n)
  local lines = read_all_lines()
  local start = math.max(1, #lines - n + 1)
  local result = {}
  for i = start, #lines do
    result[#result + 1] = lines[i]
  end
  result[#result + 1] = "."
  return table.concat(result, "\n") .. "\n"
end

local function parse_log_time(line)
  local y, mo, d, h, mi, s = line:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

local function cmd_since(minutes)
  local cutoff = os.time() - (minutes * 60)
  local lines = read_all_lines()
  local result = {}
  for _, line in ipairs(lines) do
    local t = parse_log_time(line)
    if t and t >= cutoff then
      result[#result + 1] = line
    end
  end
  result[#result + 1] = "."
  return table.concat(result, "\n") .. "\n"
end

local function cmd_status()
  local files = {}
  for i = 0, cfg.max_files - 1 do
    local path = log_path(i)
    local sz = file_size(path)
    if sz > 0 then
      files[#files + 1] = path .. ": " .. sz .. " bytes"
    end
  end

  local follower_count = 0
  for _ in pairs(followers) do follower_count = follower_count + 1 end

  local client_count = 0
  for _ in pairs(clients) do client_count = client_count + 1 end

  local lines = {
    "log_dir: " .. (love.filesystem.getSaveDirectory() or "?"),
    "files: " .. (#files > 0 and table.concat(files, ", ") or "none"),
    "rotations: " .. rotation_count,
    "uptime: " .. (start_time and math.floor(os.time() - start_time) or 0) .. "s",
    "clients: " .. client_count,
    "followers: " .. follower_count,
    "buffer: " .. #buffer .. " pending lines",
    ".",
  }
  return table.concat(lines, "\n") .. "\n"
end

local function handle_command(client, data)
  local cmd = data:match("^%s*(%S+)")
  if not cmd then return end
  cmd = cmd:lower()

  if cmd == "tail" then
    local n = tonumber(data:match("%S+%s+(%d+)")) or 100
    send_to_client(client, cmd_tail(n))

  elseif cmd == "since" then
    local minutes = tonumber(data:match("%S+%s+(%d+)")) or 10
    send_to_client(client, cmd_since(minutes))

  elseif cmd == "follow" then
    followers[client] = true
    send_to_client(client, "following\n")

  elseif cmd == "stop" then
    followers[client] = nil
    send_to_client(client, "stopped\n.\n")

  elseif cmd == "status" then
    send_to_client(client, cmd_status())

  else
    send_to_client(client, "error: unknown command '" .. cmd .. "'\ncommands: tail <n>, since <minutes>, follow, stop, status\n.\n")
  end
end

function M.update()
  flush_buffer()

  if not cfg.server_enabled then return end

  if not socket_ok then
    M.server_state = "no socket: " .. tostring(socket)
    cfg.server_enabled = false
    return
  end

  if server_failed then return end

  if not server then
    local ok, result = pcall(function()
      local s = socket.tcp()
      s:setoption("reuseaddr", true)
      s:bind("0.0.0.0", cfg.port)
      s:listen(4)
      s:settimeout(0)
      return s
    end)
    if ok and result then
      server = result
      start_time = os.time()
      M.server_state = "listening :" .. cfg.port
    else
      server_failed = true
      M.server_state = "bind failed: " .. tostring(result)
    end
    return
  end

  -- accept new connections
  local client = server:accept()
  while client do
    client:settimeout(0)
    clients[client] = true
    client_buffers[client] = ""
    client = server:accept()
  end

  -- read commands from connected clients
  local dead = {}
  for client, _ in pairs(clients) do
    local data, err, partial = client:receive("*l")
    if data then
      handle_command(client, data)
    elseif err == "closed" then
      dead[#dead + 1] = client
    elseif partial and #partial > 0 then
      local buf = (client_buffers[client] or "") .. partial
      client_buffers[client] = buf
    end
  end

  for _, client in ipairs(dead) do
    followers[client] = nil
    clients[client] = nil
    client_buffers[client] = nil
    pcall(function() client:close() end)
  end
end

function M.shutdown()
  flush_buffer()

  if server then
    for client, _ in pairs(clients) do
      pcall(function() client:close() end)
    end
    followers = {}
    clients = {}
    client_buffers = {}
    pcall(function() server:close() end)
    server = nil
  end
end

return M
