local palette = require("ble_ui.palette")
local panel = require("ble_ui.panel")
local buttons = require("ble_ui.buttons")

local M = {}

M.ROOM_CARD_HEIGHT = 120

function M.room_card(room, x, y, w, join_action, fonts, network, disable)
  panel.draw(x, y, w, M.ROOM_CARD_HEIGHT, 16, palette.panel_alt)

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print(room.name, x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(network.room_summary_text(room) .. "  " .. network.room_signal_text(room), x + 16, y + 38, w - 32)

  buttons.register(x + 16, y + 60, w - 32, 34, "Join Room", join_action, nil, disable)
end

return M
