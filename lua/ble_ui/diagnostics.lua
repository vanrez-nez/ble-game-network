local palette = require("ble_ui.palette")
local util = require("ble_ui.util")
local draw = require("ble_ui.draw")

local M = {}

local state = {
  open = false,
  scroll = 0,
  view = nil,
  dragging = false,
  drag_last_y = 0,
}

function M.is_open()
  return state.open
end

function M.open()
  state.open = true
  state.scroll = 0
  state.dragging = false
end

function M.close()
  state.open = false
  state.dragging = false
end

function M.toggle()
  if state.open then
    M.close()
  else
    M.open()
  end
end

function M.clear_view()
  state.view = nil
end

local function wrap_lines(diagnostics, font, max_width)
  local lines = {}
  for i = 1, #diagnostics do
    local _, wrapped = font:getWrap(diagnostics[i], max_width)
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

function M.adjust_scroll(delta)
  if not state.view then
    return
  end
  state.scroll = util.clamp(state.scroll + delta, 0, state.view.max_scroll or 0)
end

function M.draw(width, height, metrics, buttons, fonts, network, app)
  local margin = metrics.margin
  local safe_x, safe_y, safe_w = util.safe_area()
  local header_h = util.clamp(math.floor(height * 0.18), 108, 150)
  local log_x = margin
  local log_y = header_h
  local log_w = width - margin * 2
  local log_h = height - log_y - margin

  love.graphics.setColor(0.02, 0.03, 0.05, 0.98)
  love.graphics.rectangle("fill", 0, 0, width, height)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("BLE Diagnostics", margin, math.max(margin, safe_y + 6))

  draw.register_button(buttons, safe_x + safe_w - margin - 176, math.max(margin - 2, safe_y + 4), 80, 34, "Copy", function()
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(network.diagnostics_text())
      network.push_notice("Diagnostics copied")
    else
      network.push_notice("Clipboard is unavailable on this platform")
    end
  end, "ghost")

  draw.register_button(buttons, safe_x + safe_w - margin - 88, math.max(margin - 2, safe_y + 4), 88, 34, "Close", function()
    M.close()
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

  draw.panel(log_x, log_y, log_w, log_h, 14, palette.panel)

  local inner_x = log_x + 12
  local inner_y = log_y + 10
  local inner_w = log_w - 24
  local inner_h = log_h - 20
  local line_h = fonts.small:getHeight() + 2
  local lines = wrap_lines(app.diagnostics, fonts.small, inner_w)
  local visible = math.max(1, math.floor(inner_h / line_h))
  local max_scroll = math.max(0, #lines - visible)
  state.scroll = util.clamp(state.scroll, 0, max_scroll)

  state.view = {
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

  local start = math.max(1, #lines - visible - state.scroll + 1)
  love.graphics.setColor(palette.text)
  love.graphics.setScissor(log_x + 1, log_y + 1, log_w - 2, log_h - 2)
  for i = start, math.min(#lines, start + visible - 1) do
    love.graphics.printf(lines[i], inner_x, inner_y, inner_w)
    inner_y = inner_y + line_h
  end
  love.graphics.setScissor()
end

function M.on_pressed(x, y)
  if state.open and state.view then
    local view = state.view
    if x >= view.x and x <= view.x + view.w and y >= view.y and y <= view.y + view.h then
      state.dragging = true
      state.drag_last_y = y
    end
  end
end

function M.on_released()
  state.dragging = false
end

function M.on_moved(x, y)
  if state.open and state.dragging and state.view then
    local dy = y - state.drag_last_y
    local lines = math.floor(dy / state.view.line_h)
    if lines ~= 0 then
      M.adjust_scroll(-lines)
      state.drag_last_y = y
    end
  end
end

function M.on_touch_moved(x, y)
  if state.open and state.dragging and state.view then
    local view = state.view
    if x >= view.x and x <= view.x + view.w then
      local dy = y - state.drag_last_y
      local lines = math.floor(dy / view.line_h)
      if lines ~= 0 then
        M.adjust_scroll(-lines)
        state.drag_last_y = y
      end
    end
  end
end

function M.on_wheel(y)
  if state.open and state.view then
    M.adjust_scroll(-y * 3)
  end
end

return M
