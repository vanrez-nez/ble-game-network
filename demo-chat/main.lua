local utf8 = require("utf8")

local ble_net = require("ble_net")
local ble_ui = require("ble_ui")

local network = ble_net.new({
  title = "BLE Demo Chat",
  room_name = "Demo Chat",
  max_clients = 4,
  debug_prefix = "[demo-chat]",
})

local palette = ble_ui.palette
local diag = ble_ui.diagnostics
local app = network.state
local ui = {
  input = "",
  input_active = false,
  input_box = nil,
}

local buttons = {}
local fonts = {}
local debug_enabled = true

local function debug_log(text)
  if not debug_enabled then
    return
  end

  print("[demo-chat] " .. text)
end

local function set_input_active(active)
  ui.input_active = active and app.in_session or false
  if not ui.input_active then
    love.keyboard.setTextInput(false)
    return
  end

  local box = ui.input_box
  if box then
    love.keyboard.setTextInput(true, box.x, box.y, box.w, box.h)
  else
    love.keyboard.setTextInput(true)
  end
end

local function reset_ui_state()
  ui.input = ""
  ui.input_box = nil
  set_input_active(false)
end

local function start_host(transport)
  reset_ui_state()
  network.start_host(transport)
end

local function start_scan()
  reset_ui_state()
  network.start_scan()
end

local function leave_session()
  set_input_active(false)
  reset_ui_state()
  network.leave_session()
end

local function send_chat()
  local sent = network.send_chat(ui.input)
  if not sent then
    return
  end
  ui.input = ""
  if ui.input_active and ui.input_box then
    love.keyboard.setTextInput(true, ui.input_box.x, ui.input_box.y, ui.input_box.w, ui.input_box.h)
  end
end

local function draw_messages_card(x, y, w, h)
  ble_ui.draw.panel(x, y, w, h, 16, palette.panel)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Chat", x + 16, y + 14)

  local area_x = x + 14
  local area_y = y + 48
  local area_w = w - 28
  local gap = 10
  local cursor_y = y + h - 14

  if #app.messages == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.setFont(fonts.body)
    love.graphics.printf("Messages will appear here once someone sends chat.", area_x + 2, area_y + 8, area_w - 4)
    return
  end

  for i = #app.messages, 1, -1 do
    local item = app.messages[i]
    local bubble_w = area_w
    local _, wrapped = fonts.body:getWrap(item.text, bubble_w - 26)
    local line_count = math.max(1, #wrapped)
    local bubble_h = 26 + fonts.small:getHeight() + line_count * fonts.body:getHeight() + 10
    local bubble_y = cursor_y - bubble_h

    if bubble_y < area_y then
      break
    end

    love.graphics.setColor(item.kind == "local" and palette.accent or palette.panel_alt)
    love.graphics.rectangle("fill", area_x, bubble_y, bubble_w, bubble_h, 14, 14)
    love.graphics.setColor(item.kind == "local" and {0.09, 0.08, 0.07} or palette.text)
    love.graphics.setFont(fonts.small)
    love.graphics.print(item.author, area_x + 12, bubble_y + 8)
    love.graphics.setFont(fonts.body)
    love.graphics.printf(item.text, area_x + 12, bubble_y + 8 + fonts.small:getHeight() + 4, bubble_w - 24)

    cursor_y = bubble_y - gap
  end
end

local function draw_info_card(x, y, w, h)
  ble_ui.draw.panel(x, y, w, h, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Session", x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local info_lines = network.session_info_lines()
  for i = 1, #info_lines do
    love.graphics.printf(info_lines[i], x + 16, y + 42 + (i - 1) * 16, w - 32)
  end

  local leave_w = ble_ui.clamp(math.floor(w * 0.3), 86, 120)
  ble_ui.draw.register_button(buttons, x + w - leave_w - 16, y + 16, leave_w, 34, "Leave", leave_session, "danger")

  local peers_y = y + 132
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Peers", x + 16, peers_y)

  local row_y = peers_y + 28
  local visible_peers = math.min(#app.peers, 3)
  if visible_peers == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.setFont(fonts.small)
    love.graphics.print("No remote peers yet.", x + 16, row_y)
  else
    for i = 1, visible_peers do
      local peer = app.peers[i]
      ble_ui.draw.panel(x + 16, row_y, w - 32, 26, 10, i % 2 == 0 and palette.panel or {0.13, 0.17, 0.21})
      love.graphics.setColor(palette.text)
      love.graphics.setFont(fonts.small)
      love.graphics.print(peer.peer_id, x + 26, row_y + 6)
      if peer.is_host then
        love.graphics.setColor(palette.accent_soft)
        love.graphics.print("host", x + w - 64, row_y + 6)
      end
      row_y = row_y + 32
    end
    if #app.peers > 3 then
      love.graphics.setColor(palette.dim)
      love.graphics.setFont(fonts.small)
      love.graphics.print("+ " .. (#app.peers - 3) .. " more", x + 16, row_y + 4)
    end
  end
end

local function draw_input_card(x, y, w, h)
  ble_ui.draw.panel(x, y, w, h, 16, palette.panel)

  local send_w = ble_ui.clamp(math.floor(w * 0.22), 84, 108)
  local box_x = x + 12
  local box_y = y + 12
  local box_w = w - send_w - 30
  local box_h = h - 24
  ui.input_box = {
    x = box_x,
    y = box_y,
    w = box_w,
    h = box_h,
  }

  ble_ui.draw.panel(box_x, box_y, box_w, box_h, 12, {0.10, 0.12, 0.15})
  love.graphics.setFont(fonts.body)
  love.graphics.setColor(ui.input == "" and palette.dim or palette.text)
  love.graphics.printf(ui.input == "" and "Tap here to type..." or ui.input, box_x + 12, box_y + 10, box_w - 24)

  ble_ui.draw.register_button(buttons, x + w - send_w - 12, y + 12, send_w, h - 24, "Send", send_chat, "accent")
end

local function draw_chat(width, height, metrics)
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap
  local w = width - metrics.margin * 2

  local input_h = 70
  local info_h = ble_ui.clamp(math.floor(height * 0.26), 180, 240)
  local chat_h = height - y - metrics.margin - input_h - info_h - metrics.gap * 2
  if chat_h < 180 then
    local deficit = 180 - chat_h
    info_h = math.max(150, info_h - deficit)
    chat_h = height - y - metrics.margin - input_h - info_h - metrics.gap * 2
  end

  draw_messages_card(x, y, w, chat_h)
  draw_info_card(x, y + chat_h + metrics.gap, w, info_h)
  draw_input_card(x, y + chat_h + info_h + metrics.gap * 2, w, input_h)
end

local function pointer_pressed(x, y)
  debug_log(string.format("pointer %.1f, %.1f", x, y))
  local btn = ble_ui.draw.pointer_pressed(buttons, x, y)
  if btn then
    app.status = "Pressed " .. btn.label
    debug_log("button hit: " .. btn.label)
    return true
  end

  if app.in_session and ui.input_box then
    local box = ui.input_box
    local inside = x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h
    set_input_active(inside)
    return inside
  end

  debug_log("pointer missed buttons")
  set_input_active(false)
  return false
end

function love.load()
  love.keyboard.setKeyRepeat(true)
  fonts.title = love.graphics.newFont(22)
  fonts.section = love.graphics.newFont(18)
  fonts.subsection = love.graphics.newFont(15)
  fonts.body = love.graphics.newFont(13)
  fonts.small = love.graphics.newFont(11)
  network.initialize()
end

function love.update(dt)
  network.update()
end

function love.draw()
  buttons = {}
  ui.input_box = nil

  local width, height = love.graphics.getDimensions()
  local metrics = ble_ui.layout_metrics(width, height)

  love.graphics.clear(palette.bg)

  ble_ui.draw_frame({
    width = width,
    height = height,
    metrics = metrics,
    buttons = buttons,
    fonts = fonts,
    app = app,
    network = network,
    lobby_description = "Host a room or scan nearby devices. The portrait layout keeps every primary action reachable on a phone.",
    start_host = start_host,
    start_scan = start_scan,
    transport = ble_net.TRANSPORT,
    draw_session = function()
      draw_chat(width, height, metrics)
    end,
  })
end

function love.mousepressed(x, y, button)
  if button ~= 1 then
    return
  end
  pointer_pressed(x, y)
  diag.on_pressed(x, y)
end

function love.touchpressed(_, x, y)
  pointer_pressed(x, y)
  diag.on_pressed(x, y)
end

function love.mousereleased(_, _, button)
  if button == 1 then
    diag.on_released()
  end
end

function love.touchreleased()
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

function love.textinput(text)
  if app.in_session and ui.input_active then
    ui.input = ui.input .. text
  end
end

function love.keypressed(key)
  if key == "f1" then
    diag.toggle()
    return
  end

  if diag.is_open() and (key == "escape" or key == "back") then
    diag.close()
    return
  end

  if key == "escape" then
    if app.in_session then
      leave_session()
    end
    return
  end

  if not app.in_session then
    if key == "s" then
      start_scan()
    elseif key == "h" then
      start_host(ble_net.TRANSPORT.NORMAL)
    elseif key == "r" then
      start_host(ble_net.TRANSPORT.RESILIENT)
    end
    return
  end

  if key == "backspace" then
    local byteoffset = utf8.offset(ui.input, -1)
    if byteoffset then
      ui.input = string.sub(ui.input, 1, byteoffset - 1)
    end
  elseif key == "return" or key == "kpenter" then
    send_chat()
  elseif key == "tab" then
    set_input_active(not ui.input_active)
  end
end
