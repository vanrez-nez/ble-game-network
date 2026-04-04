local ble_net = require("ble_net")
local ble_ui = require("ble_ui")
local diag = require("ble_diagnostics")

local network = ble_net.new({
  title = "BLE Ping Pong",
  room_type = "P",
  room_name = "Ping",
  max_clients = 6,
  debug_prefix = "[pingpong]",
})

local palette = ble_ui.palette
local buttons = ble_ui.buttons
local overlay = ble_ui.overlay
local app = network.state
local fonts = {}

local debug_overlay = require("ble_debug").new(network)

-- Peer tracking: peer_id -> { last_ping_sent, last_pong_recv, flash_send, flash_recv, seq }
local peers = {}
local FLASH_DURATION = 0.3
local PING_INTERVAL = 1.0

local function get_peer(peer_id)
  if not peers[peer_id] then
    peers[peer_id] = {
      last_ping_sent = 0,
      last_pong_recv = 0,
      flash_send = 0,
      flash_recv = 0,
      seq = 0,
      latency = nil,
    }
  end
  return peers[peer_id]
end

local function send_ping(peer_id)
  local p = get_peer(peer_id)
  p.seq = p.seq + 1
  p.last_ping_sent = love.timer.getTime()
  p.flash_send = love.timer.getTime()
  network.send_payload(peer_id, "ping", { seq = p.seq, t = love.timer.getTime() })
end

local function send_pong(peer_id, seq, t)
  local p = get_peer(peer_id)
  p.flash_send = love.timer.getTime()
  network.send_payload(peer_id, "pong", { seq = seq, t = t })
end

local function handle_event(ev)
  if ev.type == "hosted" then
    peers = {}
  elseif ev.type == "joined" then
    peers = {}
  elseif ev.type == "session_resumed" then
    peers = {}
  elseif ev.type == "peer_left" then
    peers[ev.peer_id] = nil
  elseif ev.type == "peer_status" then
    local p = get_peer(ev.peer_id)
    if ev.status == "reconnecting" then
      p.flash_send = 0
      p.flash_recv = 0
    elseif ev.status == "connected" then
      p.last_ping_sent = 0
    end
  elseif ev.type == "session_ended" then
    peers = {}
  elseif ev.type == "message" then
    if not ev.payload then return end
    if ev.msg_type == "ping" then
      local p = get_peer(ev.peer_id)
      p.flash_recv = love.timer.getTime()
      send_pong(ev.peer_id, ev.payload.seq, ev.payload.t)
    elseif ev.msg_type == "pong" then
      local p = get_peer(ev.peer_id)
      p.flash_recv = love.timer.getTime()
      p.last_pong_recv = love.timer.getTime()
      if ev.payload.t then
        p.latency = love.timer.getTime() - ev.payload.t
      end
    end
  end
end

local function start_host(transport)
  peers = {}
  network.start_host(transport)
end

local function start_scan()
  peers = {}
  network.start_scan()
end

local function leave()
  peers = {}
  network.leave_session()
end

local touch_handled = false

local function handle_press(x, y)
  buttons.pressed(x, y)
  diag.on_pressed(x, y)
end

function love.load()
  fonts.title = love.graphics.newFont(22)
  fonts.section = love.graphics.newFont(18)
  fonts.subsection = love.graphics.newFont(15)
  fonts.body = love.graphics.newFont(13)
  fonts.small = love.graphics.newFont(11)

  network.set_event_handler(handle_event)
  network.initialize()
end

function love.update(dt)
  network.update()

  if not app.in_session then return end

  local now = love.timer.getTime()
  for i = 1, #app.peers do
    local peer = app.peers[i]
    if peer.peer_id ~= app.local_id and network.is_peer_connected(peer.peer_id) then
      local p = get_peer(peer.peer_id)
      if now - p.last_ping_sent >= PING_INTERVAL then
        send_ping(peer.peer_id)
      end
    end
  end
end

local function draw_session(width, height, metrics)
  local now = love.timer.getTime()
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap + 10
  local w = width - metrics.margin * 2

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf("me: " .. app.local_id .. (app.is_host and " (host)" or ""), x, y, w, "center")
  y = y + 20

  local peer_list = {}
  for i = 1, #app.peers do
    if app.peers[i].peer_id ~= app.local_id then
      peer_list[#peer_list + 1] = app.peers[i]
    end
  end

  if #peer_list == 0 then
    love.graphics.setFont(fonts.body)
    love.graphics.setColor(palette.dim)
    love.graphics.printf("Waiting for peers...", x, y + 40, w, "center")

    buttons.register(x + 10, height - metrics.margin - 44, w - 20, 44, "Leave", leave, "danger")
    return
  end

  local card_h = 80
  local gap = 12

  for i = 1, #peer_list do
    local peer = peer_list[i]
    local p = get_peer(peer.peer_id)
    local peer_status = network.peer_status(peer.peer_id)
    local card_y = y + (i - 1) * (card_h + gap)

    -- Card background
    love.graphics.setColor(0.12, 0.14, 0.18)
    love.graphics.rectangle("fill", x, card_y, w, card_h, 10, 10)

    -- Flash green on send
    local send_age = now - p.flash_send
    if send_age < FLASH_DURATION then
      local alpha = 0.4 * (1.0 - send_age / FLASH_DURATION)
      love.graphics.setColor(0.2, 0.8, 0.4, alpha)
      love.graphics.rectangle("fill", x, card_y, w * 0.5, card_h, 10, 0)
    end

    -- Flash green on recv
    local recv_age = now - p.flash_recv
    if recv_age < FLASH_DURATION then
      local alpha = 0.4 * (1.0 - recv_age / FLASH_DURATION)
      love.graphics.setColor(0.2, 0.8, 0.4, alpha)
      love.graphics.rectangle("fill", x + w * 0.5, card_y, w * 0.5, card_h, 0, 10)
    end

    -- Border
    love.graphics.setColor(palette.stroke)
    love.graphics.rectangle("line", x, card_y, w, card_h, 10, 10)

    -- Peer ID
    love.graphics.setFont(fonts.body)
    love.graphics.setColor(palette.text)
    love.graphics.print(peer.peer_id .. (peer.is_host and " (host)" or ""), x + 12, card_y + 10)

    -- Latency
    love.graphics.setFont(fonts.small)
    if peer_status == "reconnecting" then
      love.graphics.setColor(palette.accent)
      love.graphics.print("reconnecting", x + w - 102, card_y + 12)
    elseif p.latency then
      local ms = math.floor(p.latency * 1000)
      love.graphics.setColor(ms < 100 and palette.success or (ms < 500 and palette.accent or palette.danger))
      love.graphics.print(ms .. "ms", x + w - 60, card_y + 12)
    else
      love.graphics.setColor(palette.dim)
      love.graphics.print("--", x + w - 40, card_y + 12)
    end

    -- Arrows
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(palette.dim)
    local labels = "PING ->          <- PONG"
    love.graphics.printf(labels, x + 12, card_y + 34, w - 24, "center")

    -- Heartbeat dot
    local alive = peer_status ~= "reconnecting" and (now - p.last_pong_recv) < (PING_INTERVAL * 2.5)
    love.graphics.setColor(peer_status == "reconnecting" and palette.accent or (alive and palette.success or palette.danger))
    love.graphics.circle("fill", x + w - 20, card_y + card_h - 16, 5)

    -- Last pong age
    if peer_status == "reconnecting" then
      love.graphics.setFont(fonts.small)
      love.graphics.setColor(palette.dim)
      love.graphics.print("Waiting to reconnect...", x + 12, card_y + card_h - 20)
    elseif p.last_pong_recv > 0 then
      local age = now - p.last_pong_recv
      love.graphics.setFont(fonts.small)
      love.graphics.setColor(palette.dim)
      love.graphics.print(string.format("%.1fs ago", age), x + 12, card_y + card_h - 20)
    end
  end

  buttons.register(x + 10, height - metrics.margin - 44, w - 20, 44, "Leave", leave, "danger")
end

function love.draw()
  local width, height = love.graphics.getDimensions()
  local metrics = ble_ui.layout_metrics(width, height)
  love.graphics.clear(palette.bg)

  diag.set_context(network, app)

  ble_ui.draw_frame({
    width = width,
    height = height,
    metrics = metrics,
    fonts = fonts,
    app = app,
    network = network,
    overlays = { diag.get_overlay(), debug_overlay },
    lobby_description = "Host or scan to start ping-pong between all connected devices. Each peer sends pings and measures round-trip latency.",
    start_host = start_host,
    start_scan = start_scan,
    transport = ble_net.TRANSPORT,
    draw_session = function()
      draw_session(width, height, metrics)
    end,
    extra_buttons = function()
      local btn_h = 28
      local btn_y = math.floor((metrics.topbar_h - btn_h) * 0.5)
      buttons.register(width - 8 - 64, btn_y, 64, btn_h, "Logs", function()
        diag.toggle()
      end, "ghost")
      buttons.register(width - 8 - 64 - 8 - 52, btn_y, 52, btn_h, "DBG", function()
        debug_overlay:toggle()
      end, "ghost")
    end,
  })
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  if touch_handled then touch_handled = false; return end
  handle_press(x, y)
end

function love.touchpressed(_, x, y)
  touch_handled = true
  handle_press(x, y)
end

function love.mousereleased(x, y, button)
  if button == 1 then
    buttons.mousereleased(x, y)
    diag.on_released()
  end
end

function love.touchreleased(_, x, y)
  buttons.mousereleased(x or 0, y or 0)
  diag.on_released()
end

function love.mousemoved(_, y)
  diag.on_moved(0, y)
end

function love.touchmoved(_, x, y)
  diag.on_touch_moved(x, y)
end

function love.wheelmoved(_, y)
  diag.on_wheel(y)
end

function love.keypressed(key)
  if diag.is_open() and (key == "escape" or key == "back") then diag.close(); return end
  if key == "back" or key == "escape" then
    if app.in_session then leave() end
  end
end
