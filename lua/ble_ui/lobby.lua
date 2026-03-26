local palette = require("ble_ui.palette")
local buttons = require("ble_ui.buttons")
local panel = require("ble_ui.panel")
local draw = require("ble_ui.draw")

local M = {}

function M.draw(width, height, metrics, opts)
  local fonts = opts.fonts
  local app = opts.app
  local network = opts.network
  local description = opts.description
  local start_host = opts.start_host
  local start_scan = opts.start_scan
  local transport = opts.transport

  local panel_x = metrics.margin
  local panel_y = metrics.topbar_h + metrics.gap
  local panel_w = width - metrics.margin * 2
  local panel_h = height - panel_y - metrics.margin

  panel.draw(panel_x, panel_y, panel_w, panel_h, metrics.radius, palette.panel)

  local cursor_y = panel_y + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section)
  love.graphics.print("Lobby", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 30
  love.graphics.setFont(fonts.body)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(description, panel_x + 18, cursor_y, panel_w - 36)

  cursor_y = cursor_y + 64
  buttons.register(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Normal", function()
    start_host(transport.NORMAL)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  buttons.register(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Host Resilient", function()
    start_host(transport.RESILIENT)
  end, "accent")

  cursor_y = cursor_y + metrics.button_h + metrics.gap
  buttons.register(panel_x + 18, cursor_y, panel_w - 36, metrics.button_h, "Scan Rooms", start_scan)

  cursor_y = cursor_y + metrics.button_h + 18
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print("Status", panel_x + 18, cursor_y)

  cursor_y = cursor_y + 28
  panel.draw(panel_x + 18, cursor_y, panel_w - 36, 54, 14, {0.10, 0.12, 0.15})
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

  local card_step = draw.ROOM_CARD_HEIGHT + 10
  local max_cards = math.max(1, math.floor((panel_h - (cursor_y - panel_y) - 18) / card_step))
  for i = 1, math.min(#app.rooms, max_cards) do
    local room = app.rooms[i]
    draw.room_card(room, panel_x + 18, cursor_y, panel_w - 36, function()
      network.join_room(room.room_id, room.name)
    end, fonts, network)
    cursor_y = cursor_y + card_step
  end
end

return M
