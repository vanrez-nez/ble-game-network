local utf8 = require("utf8")
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;../lua/?.lua;../lua/?/init.lua"

local ble_net = require("ble_net")
local network = ble_net.new({
  title = "BLE Demo Chat",
  room_name = "Demo Chat",
  max_clients = 4,
  debug_prefix = "[demo-chat]",
})

local palette = {
  bg = {0.07, 0.09, 0.12},
  panel = {0.11, 0.14, 0.18},
  panel_alt = {0.15, 0.19, 0.24},
  stroke = {0.24, 0.29, 0.35},
  accent = {0.97, 0.62, 0.28},
  accent_soft = {0.96, 0.79, 0.57},
  text = {0.95, 0.96, 0.98},
  dim = {0.61, 0.67, 0.75},
  success = {0.36, 0.82, 0.57},
  danger = {0.90, 0.36, 0.35},
}

local app = network.state
local ui = {
  input = "",
  input_active = false,
  input_box = nil,
  diagnostics_open = false,
  diagnostics_scroll = 0,
  diagnostics_view = nil,
  diagnostics_dragging = false,
  diagnostics_drag_last_y = 0,
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

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function layout_metrics(width, height)
  local margin = clamp(math.floor(width * 0.04), 14, 24)
  local gap = clamp(math.floor(width * 0.024), 10, 18)
  local topbar_h = clamp(math.floor(height * 0.095), 72, 88)
  return {
    margin = margin,
    gap = gap,
    radius = 18,
    topbar_h = topbar_h,
    button_h = clamp(math.floor(height * 0.06), 42, 50),
  }
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

local function diagnostics_lines(max_width)
  local lines = {}
  for i = 1, #app.diagnostics do
    local _, wrapped = fonts.small:getWrap(app.diagnostics[i], max_width)
    if #wrapped == 0 then
      lines[#lines + 1] = ""
    else
      for j = 1, #wrapped do
        lines[#lines + 1] = wrapped[j]
      end
    end
  end
  return lines
end

local function safe_area()
  if love.window and love.window.getSafeArea then
    local x, y, w, h = love.window.getSafeArea()
    if x and y and w and h then
      return x, y, w, h
    end
  end

  local width, height = love.graphics.getDimensions()
  return 0, 0, width, height
end

local function adjust_diagnostics_scroll(delta)
  local view = ui.diagnostics_view
  if not view then
    return
  end

  ui.diagnostics_scroll = clamp(ui.diagnostics_scroll + delta, 0, view.max_scroll or 0)
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

local function register_button(x, y, w, h, label, action, style)
  buttons[#buttons + 1] = {
    x = x,
    y = y,
    w = w,
    h = h,
    label = label,
    action = action,
    style = style or "default",
  }
end

local function draw_panel(x, y, w, h, radius, fill)
  love.graphics.setColor(fill or palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, radius, radius)
  love.graphics.setColor(palette.stroke)
  love.graphics.rectangle("line", x, y, w, h, radius, radius)
end

local function draw_button(btn)
  local mx, my = love.mouse.getPosition()
  local hot = mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h
  local fill = palette.panel_alt
  local text = palette.text

  if btn.style == "accent" then
    fill = hot and palette.accent_soft or palette.accent
    text = {0.09, 0.08, 0.07}
  elseif btn.style == "danger" then
    fill = hot and {0.96, 0.49, 0.46} or palette.danger
    text = {0.09, 0.08, 0.07}
  elseif btn.style == "ghost" then
    fill = hot and {0.18, 0.23, 0.29, 0.96} or {0.11, 0.14, 0.18, 0.92}
    text = hot and palette.text or palette.dim
  elseif hot then
    fill = {0.20, 0.25, 0.31}
  end

  love.graphics.setColor(fill)
  love.graphics.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 14, 14)
  love.graphics.setColor(btn.style == "ghost" and palette.stroke or {0, 0, 0, 0.18})
  love.graphics.rectangle("line", btn.x, btn.y, btn.w, btn.h, 14, 14)
  love.graphics.setColor(text)
  love.graphics.setFont(fonts.body)
  love.graphics.printf(btn.label, btn.x + 10, btn.y + math.floor((btn.h - fonts.body:getHeight()) * 0.5), btn.w - 20, "center")
end

local function draw_diagnostics_overlay(width, height, metrics)
  local margin = metrics.margin
  local safe_x, safe_y, safe_w = safe_area()
  local header_h = clamp(math.floor(height * 0.18), 108, 150)
  local log_x = margin
  local log_y = header_h
  local log_w = width - margin * 2
  local log_h = height - log_y - margin

  love.graphics.setColor(0.02, 0.03, 0.05, 0.98)
  love.graphics.rectangle("fill", 0, 0, width, height)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("BLE Diagnostics", margin, math.max(margin, safe_y + 6))

  register_button(safe_x + safe_w - margin - 176, math.max(margin - 2, safe_y + 4), 80, 34, "Copy", function()
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(network.diagnostics_text())
      network.push_notice("Diagnostics copied")
    else
      network.push_notice("Clipboard is unavailable on this platform")
    end
  end, "ghost")

  register_button(safe_x + safe_w - margin - 88, math.max(margin - 2, safe_y + 4), 88, 34, "Close", function()
    ui.diagnostics_open = false
    ui.diagnostics_dragging = false
  end, "danger")

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local meta_y = math.max(margin, safe_y + 6) + 34
  local meta_w = width - margin * 2
  local meta = network.diagnostics_meta_lines()
  for i = 1, #meta do
    love.graphics.printf(meta[i], margin, meta_y, meta_w)
    meta_y = meta_y + fonts.small:getHeight() + 3
  end

  draw_panel(log_x, log_y, log_w, log_h, 14, palette.panel)

  local inner_x = log_x + 12
  local inner_y = log_y + 10
  local inner_w = log_w - 24
  local inner_h = log_h - 20
  local line_h = fonts.small:getHeight() + 2
  local lines = diagnostics_lines(inner_w)
  local visible = math.max(1, math.floor(inner_h / line_h))
  local max_scroll = math.max(0, #lines - visible)
  ui.diagnostics_scroll = clamp(ui.diagnostics_scroll, 0, max_scroll)

  ui.diagnostics_view = {
    x = log_x,
    y = log_y,
    w = log_w,
    h = log_h,
    line_h = line_h,
    max_scroll = max_scroll,
  }

  if #lines == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.printf("No BLE diagnostics yet.", inner_x, inner_y, inner_w)
    return
  end

  local start = math.max(1, #lines - visible - ui.diagnostics_scroll + 1)
  love.graphics.setColor(palette.text)
  love.graphics.setScissor(log_x + 1, log_y + 1, log_w - 2, log_h - 2)
  for i = start, math.min(#lines, start + visible - 1) do
    love.graphics.printf(lines[i], inner_x, inner_y, inner_w)
    inner_y = inner_y + line_h
  end
  love.graphics.setScissor()
end

local function draw_topbar(width, metrics)
  draw_panel(0, 0, width, metrics.topbar_h, 0, palette.panel)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.title)
  love.graphics.print(app.title, metrics.margin, 16)
end

local function draw_room_card(room, x, y, w, join_action)
  draw_panel(x, y, w, 106, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print(room.name, x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(
    network.room_summary_text(room),
    x + 16,
    y + 42,
    w - 32
  )
  love.graphics.printf(network.room_signal_text(room), x + 16, y + 60, w - 32)

  register_button(x + 16, y + 66, w - 32, 28, "Join Room", join_action)
end

local function draw_menu(width, height, metrics)
  local panel_x = metrics.margin
  local panel_y = metrics.topbar_h + metrics.gap
  local panel_w = width - metrics.margin * 2
  local panel_h = height - panel_y - metrics.margin

  draw_panel(panel_x, panel_y, panel_w, panel_h, metrics.radius, palette.panel)

  local cursor_y = panel_y + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Lobby", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 30
  love.graphics.setFont(fonts.body)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(
    "Host a room or scan nearby devices. The portrait layout keeps every primary action reachable on a phone.",
    panel_x + 18,
    cursor_y,
    panel_w - 36
  )

  cursor_y = cursor_y + 64
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Reliable", function()
    start_host(ble_net.TRANSPORT.RELIABLE)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Resilient", function()
    start_host(ble_net.TRANSPORT.RESILIENT)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  register_button(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Scan Rooms", start_scan)

  cursor_y = cursor_y + metrics.button_h + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Status", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 28
  draw_panel(panel_x + 18, cursor_y, panel_w - 36, 54, 14, {0.10, 0.12, 0.15})
  love.graphics.setColor(palette.dim)
  love.graphics.setFont(fonts.body)
  love.graphics.printf(app.status, panel_x + 30, cursor_y + 10, panel_w - 60)

  cursor_y = cursor_y + 70
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Discovered Rooms", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 30
  if #app.rooms == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.setFont(fonts.body)
    love.graphics.printf("No rooms visible yet.", panel_x + 18, cursor_y, panel_w - 36)
    return
  end

  local max_cards = math.max(1, math.floor((panel_h - (cursor_y - panel_y) - 18) / 116))
  for i = 1, math.min(#app.rooms, max_cards) do
    local room = app.rooms[i]
    draw_room_card(room, panel_x + 18, cursor_y, panel_w - 36, function()
      network.join_room(room.room_id, room.name)
    end)
    cursor_y = cursor_y + 116
  end
end

local function draw_messages_card(x, y, w, h)
  draw_panel(x, y, w, h, 16, palette.panel)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Chat", x + 16, y + 14)

  local area_x = x + 14
  local area_y = y + 48
  local area_w = w - 28
  local area_h = h - 62
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
  draw_panel(x, y, w, h, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Session", x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local info_lines = network.session_info_lines()
  for i = 1, #info_lines do
    love.graphics.printf(info_lines[i], x + 16, y + 42 + (i - 1) * 16, w - 32)
  end

  local leave_w = clamp(math.floor(w * 0.3), 86, 120)
  register_button(x + w - leave_w - 16, y + 16, leave_w, 34, "Leave", leave_session, "danger")

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
      draw_panel(x + 16, row_y, w - 32, 26, 10, i % 2 == 0 and palette.panel or {0.13, 0.17, 0.21})
      love.graphics.setColor(palette.text)
      love.graphics.setFont(fonts.small)
      love.graphics.print(peer.peer_id, x + 26, row_y + 6)
      if peer.is_host then
        love.graphics.setColor(palette.accent_soft)
        love.graphics.print("host", x + w - 64, row_y + 6)
      end
      row_y = row_y + 32
    end
  end

end

local function draw_input_card(x, y, w, h)
  draw_panel(x, y, w, h, 16, palette.panel)

  local send_w = clamp(math.floor(w * 0.22), 84, 108)
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

  draw_panel(box_x, box_y, box_w, box_h, 12, {0.10, 0.12, 0.15})
  love.graphics.setFont(fonts.body)
  love.graphics.setColor(ui.input == "" and palette.dim or palette.text)
  love.graphics.printf(ui.input == "" and "Tap here to type..." or ui.input, box_x + 12, box_y + 10, box_w - 24)

  register_button(x + w - send_w - 12, y + 12, send_w, h - 24, "Send", send_chat, "accent")
end

local function draw_chat(width, height, metrics)
  local x = metrics.margin
  local y = metrics.topbar_h + metrics.gap
  local w = width - metrics.margin * 2

  local input_h = 70
  local info_h = clamp(math.floor(height * 0.26), 180, 240)
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
  for i = 1, #buttons do
    local btn = buttons[i]
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      app.status = "Pressed " .. btn.label
      debug_log("button hit: " .. btn.label)
      btn.action()
      return true
    end
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
  local metrics = layout_metrics(width, height)

  love.graphics.clear(palette.bg)
  ui.diagnostics_view = nil

  if ui.diagnostics_open then
    draw_diagnostics_overlay(width, height, metrics)
  else
    draw_topbar(width, metrics)

    if app.in_session then
      draw_chat(width, height, metrics)
    else
      draw_menu(width, height, metrics)
    end

    local corner_inset = 8
    register_button(width - corner_inset - 64, corner_inset, 64, 28, "Logs", function()
      ui.diagnostics_open = true
      ui.diagnostics_scroll = 0
      ui.diagnostics_dragging = false
    end, "ghost")
  end

  for i = 1, #buttons do
    draw_button(buttons[i])
  end
end

function love.mousepressed(x, y, button)
  if button ~= 1 then
    return
  end

  pointer_pressed(x, y)

  if ui.diagnostics_open and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w and y >= view.y and y <= view.y + view.h then
      ui.diagnostics_dragging = true
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.touchpressed(_, x, y)
  pointer_pressed(x, y)

  if ui.diagnostics_open and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w and y >= view.y and y <= view.y + view.h then
      ui.diagnostics_dragging = true
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.mousereleased(_, _, button)
  if button == 1 then
    ui.diagnostics_dragging = false
  end
end

function love.touchreleased()
  ui.diagnostics_dragging = false
end

function love.mousemoved(_, y)
  if ui.diagnostics_open and ui.diagnostics_dragging and ui.diagnostics_view then
    local dy = y - ui.diagnostics_drag_last_y
    local lines = math.floor(dy / ui.diagnostics_view.line_h)
    if lines ~= 0 then
      adjust_diagnostics_scroll(-lines)
      ui.diagnostics_drag_last_y = y
    end
  end
end

function love.touchmoved(_, x, y)
  if ui.diagnostics_open and ui.diagnostics_dragging and ui.diagnostics_view then
    local view = ui.diagnostics_view
    if x >= view.x and x <= view.x + view.w then
      local dy = y - ui.diagnostics_drag_last_y
      local lines = math.floor(dy / view.line_h)
      if lines ~= 0 then
        adjust_diagnostics_scroll(-lines)
        ui.diagnostics_drag_last_y = y
      end
    end
  end
end

function love.wheelmoved(_, y)
  if ui.diagnostics_open and ui.diagnostics_view then
    adjust_diagnostics_scroll(-y * 3)
  end
end

function love.textinput(text)
  if app.in_session and ui.input_active then
    ui.input = ui.input .. text
  end
end

function love.keypressed(key)
  if key == "f1" then
    ui.diagnostics_open = not ui.diagnostics_open
    ui.diagnostics_dragging = false
    return
  end

  if ui.diagnostics_open and (key == "escape" or key == "back") then
    ui.diagnostics_open = false
    ui.diagnostics_dragging = false
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
      start_host(ble_net.TRANSPORT.RELIABLE)
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
