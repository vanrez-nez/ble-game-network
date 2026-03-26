local palette = require("ble_ui.palette")
local util = require("ble_ui.util")
local panel = require("ble_ui.panel")
local buttons = require("ble_ui.buttons")
local overlay_mod = require("ble_ui.overlay")

local M = {}

local state = {
  scroll = 0,
  view = nil,
  dragging = false,
  drag_last_y = 0,
  network = nil,
  app = nil,
}

local filters = {
  connection = true,
  message = true,
  session = true,
  heartbeat = false,
  scan = false,
}

local filter_order = { "connection", "message", "session", "heartbeat", "scan" }

local filter_labels = {
  connection = "Conn",
  message = "Msg",
  session = "Sess",
  heartbeat = "HB",
  scan = "Scan",
}

local cat_colors = {
  connection = {0.3, 0.85, 0.5},
  message = {0.4, 0.7, 0.95},
  heartbeat = {0.5, 0.55, 0.6},
  scan = {0.85, 0.8, 0.4},
  session = {0.8, 0.85, 0.9},
}

local cat_tags = {
  connection = "[conn] ",
  message = "[msg]  ",
  heartbeat = "[hb]   ",
  scan = "[scan] ",
  session = "[sess] ",
}

local instance = overlay_mod.new({ title = "BLE Logs" })

function M.is_open() return instance:is_open() end
function M.open() instance:open(); state.scroll = 0; state.dragging = false end
function M.close() instance:close(); state.dragging = false end
function M.toggle() if instance:is_open() then M.close() else M.open() end end

function M.set_context(network, app)
  state.network = network
  state.app = app
end

function M.get_overlay() return instance end

local function adjust_scroll(delta)
  if not state.view then return end
  state.scroll = util.clamp(state.scroll + delta, 0, state.view.max_scroll or 0)
end

local _filtered_buf = {}
local function get_filtered_entries(diagnostics)
  local n = 0
  for i = 1, #diagnostics do
    local d = diagnostics[i]
    if type(d) == "table" and d.cat and filters[d.cat] then
      n = n + 1
      _filtered_buf[n] = d
    end
  end
  for i = n + 1, #_filtered_buf do _filtered_buf[i] = nil end
  return _filtered_buf, n
end

instance.content_fn = function(cx, cy, cw, ch, fonts)
  local network = state.network
  local app = state.app
  if not network or not app then return end

  -- Copy button
  buttons.register(cx + cw - 176, cy - 36, 80, 34, "Copy", function()
    if love.system and love.system.setClipboardText then
      love.system.setClipboardText(network.diagnostics_text())
      network.push_notice("Diagnostics copied")
    else
      network.push_notice("Clipboard is unavailable on this platform")
    end
  end, "ghost")

  -- Meta info
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  local content_y = cy

  -- Reserve space for filter bar at bottom
  local filter_bar_h = 36
  local log_y = content_y + 4
  local log_h = ch - (log_y - cy) - filter_bar_h - 8
  if log_h < 40 then return end

  -- Log panel
  panel.draw(cx, log_y, cw, log_h, 14, palette.panel)

  local inner_x = cx + 10
  local inner_y = log_y + 8
  local inner_w = cw - 20
  local inner_h = log_h - 16
  local line_h = fonts.small:getHeight() + 2

  local entries, entry_count = get_filtered_entries(app.diagnostics)

  local visible = math.max(1, math.floor(inner_h / line_h))
  local max_scroll = math.max(0, entry_count - visible)
  state.scroll = util.clamp(state.scroll, 0, max_scroll)

  state.view = {
    x = cx, y = log_y, w = cw, h = log_h,
    line_h = line_h, max_scroll = max_scroll,
  }

  if entry_count == 0 then
    love.graphics.setColor(palette.dim)
    love.graphics.printf("No matching log entries.", inner_x, inner_y, inner_w)
  else
    local start = math.max(1, entry_count - visible - state.scroll + 1)
    love.graphics.setFont(fonts.small)
    love.graphics.setScissor(cx + 1, log_y + 1, cw - 2, log_h - 2)
    for i = start, math.min(entry_count, start + visible - 1) do
      local e = entries[i]
      local color = cat_colors[e.cat] or palette.text
      love.graphics.setColor(color)
      local tag = cat_tags[e.cat] or ""
      love.graphics.printf(tag .. e.text, inner_x, inner_y, inner_w)
      inner_y = inner_y + line_h
    end
    love.graphics.setScissor()
  end

  -- Filter bar at bottom
  local radius = 6
  local filter_y = log_y + log_h + 8
  local filter_x = cx
  love.graphics.setFont(fonts.small)
  local text_h = fonts.small:getHeight()

  for _, cat in ipairs(filter_order) do
    local color = cat_colors[cat] or palette.text
    local label = filter_labels[cat]
    local label_w = fonts.small:getWidth(label)
    local item_w = radius * 2 + 6 + label_w + 14

    if filter_x + item_w > cx + cw then
      filter_x = cx
      filter_y = filter_y + filter_bar_h
    end

    local circle_x = filter_x + radius + 4
    local circle_y = filter_y + math.floor(filter_bar_h * 0.5)

    -- Hit area (invisible button)
    buttons.register(filter_x, filter_y, item_w, filter_bar_h, "", function()
      filters[cat] = not filters[cat]
    end, "invisible")

    -- Circle
    if filters[cat] then
      love.graphics.setColor(color)
      love.graphics.circle("fill", circle_x, circle_y, radius)
    else
      love.graphics.setColor(0.35, 0.38, 0.44)
      love.graphics.circle("line", circle_x, circle_y, radius)
    end

    -- Label
    love.graphics.setColor(filters[cat] and color or {0.4, 0.42, 0.48})
    love.graphics.print(label, filter_x + radius * 2 + 10, filter_y + math.floor((filter_bar_h - text_h) * 0.5))

    filter_x = filter_x + item_w
  end
end

function M.on_pressed(x, y)
  if instance:is_open() and state.view then
    local v = state.view
    if x >= v.x and x <= v.x + v.w and y >= v.y and y <= v.y + v.h then
      state.dragging = true; state.drag_last_y = y
    end
  end
end

function M.on_released() state.dragging = false end

function M.on_moved(x, y)
  if instance:is_open() and state.dragging and state.view then
    local dy = y - state.drag_last_y
    local lines = math.floor(dy / state.view.line_h)
    if lines ~= 0 then adjust_scroll(-lines); state.drag_last_y = y end
  end
end

function M.on_touch_moved(x, y)
  if instance:is_open() and state.dragging and state.view then
    local v = state.view
    if x >= v.x and x <= v.x + v.w then
      local dy = y - state.drag_last_y
      local lines = math.floor(dy / v.line_h)
      if lines ~= 0 then adjust_scroll(-lines); state.drag_last_y = y end
    end
  end
end

function M.on_wheel(y)
  if instance:is_open() and state.view then adjust_scroll(-y * 3) end
end

return M
