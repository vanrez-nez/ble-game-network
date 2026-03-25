local palette = require("ble_ui.palette")

local M = {}

function M.register_button(buttons, x, y, w, h, label, action, style)
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

function M.panel(x, y, w, h, radius, fill)
  love.graphics.setColor(fill or palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, radius, radius)
  love.graphics.setColor(palette.stroke)
  love.graphics.rectangle("line", x, y, w, h, radius, radius)
end

function M.button(btn, fonts)
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

function M.topbar(width, metrics, title, fonts)
  M.panel(0, 0, width, metrics.topbar_h, 0, palette.panel)
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.title)
  local title_y = math.floor((metrics.topbar_h - fonts.title:getHeight()) * 0.5)
  love.graphics.print(title, metrics.margin, title_y)
end

function M.room_card(room, x, y, w, join_action, buttons, fonts, network)
  M.panel(x, y, w, 106, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print(room.name, x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(network.room_summary_text(room), x + 16, y + 42, w - 32)
  love.graphics.printf(network.room_signal_text(room), x + 16, y + 60, w - 32)

  M.register_button(buttons, x + 16, y + 66, w - 32, 28, "Join Room", join_action)
end

function M.pointer_pressed(buttons, x, y)
  for i = 1, #buttons do
    local btn = buttons[i]
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      btn.action()
      return btn
    end
  end
  return nil
end

return M
