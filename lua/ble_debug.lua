local overlay_mod = require("ble_ui.overlay")
local ble_log = require("ble_log")

local M = {}

local cached_ip = nil
local ip_refresh_at = 0

local function get_local_ip()
  local now = os.time()
  if cached_ip and now < ip_refresh_at then return cached_ip end
  local ok, socket = pcall(require, "socket")
  if ok and socket then
    local s = socket.udp()
    s:setpeername("192.0.2.1", 80)
    local ip = s:getsockname()
    s:close()
    cached_ip = ip or "?"
  else
    cached_ip = "?"
  end
  ip_refresh_at = now + 10
  return cached_ip
end

function M.new(network, opts)
  opts = opts or {}
  local instance = overlay_mod.new({ title = opts.title or "Debug State" })

  instance.content_fn = function(cx, cy, cw, ch, f)
    love.graphics.setFont(f.small)
    local lh = f.small:getHeight() + 2

    local function line(text, color)
      love.graphics.setColor(color or {0.80, 0.85, 0.65})
      love.graphics.print(text, cx, cy)
      cy = cy + lh
    end

    -- native state
    local dbg = love.ble and love.ble.debug_state and love.ble.debug_state() or ""
    line("build: " .. (dbg:match("build=(%S+)") or "?"))
    line("address: " .. (dbg:match("address=(%S+)") or "?"))
    line("ip: " .. get_local_ip())
    line("log_server: " .. tostring(ble_log.server_state))

    -- network state
    local app = network.state
    line("local_id: " .. tostring(app.local_id))
    line("is_host: " .. tostring(app.is_host))
    line("in_session: " .. tostring(app.in_session))
    line("peers: " .. #app.peers)
    for i = 1, #app.peers do
      local p = app.peers[i]
      line("  " .. p.peer_id .. (p.is_host and " (host)" or ""))
    end
    line("status: " .. tostring(app.status))

    -- last message in/out
    local now = love.timer.getTime()
    if network.last_in then
      local age = string.format("%.1fs", now - network.last_in.time)
      line("last_in: " .. tostring(network.last_in.msg_type) .. " from " .. tostring(network.last_in.peer_id) .. " " .. age)
    end
    if network.last_out then
      local age = string.format("%.1fs", now - network.last_out.time)
      line("last_out: " .. tostring(network.last_out.msg_type) .. " " .. age)
    end

    -- demo-specific extra content
    if opts.extra then
      cy = cy + 4
      opts.extra(cx, cy, cw, ch - (cy - cx), f, line)
    end
  end

  return instance
end

return M
