local palette = require("ble_ui.palette")
local panel = require("ble_ui.panel")
local buttons = require("ble_ui.buttons")

local M = {}

M.ROOM_CARD_HEIGHT = 120

function M.room_card(room, x, y, w, join_action, fonts, network, disable)
  panel.draw(x, y, w, M.ROOM_CARD_HEIGHT, 16, palette.panel_alt)
  local join_enabled = network.can_join_room(room)
  local join_disable = disable
  if not join_enabled then
    join_disable = { interactable = false }
  end

  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.subsection)
  love.graphics.print(network.room_title_text(room), x + 16, y + 14)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(palette.dim)
  love.graphics.printf(network.room_summary_text(room) .. "  " .. network.room_signal_text(room), x + 16, y + 38, w - 32)

  if room.incompatible then
    love.graphics.setColor(palette.danger)
    love.graphics.setFont(fonts.small)
    love.graphics.printf("This room uses protocol v" .. tostring(room.proto_version or "?") .. ".", x + 16, y + 60, w - 32)
  end

  buttons.register(x + 16, y + 82, w - 32, 26, network.join_button_text(room), join_action, nil, join_disable)
end

return M
