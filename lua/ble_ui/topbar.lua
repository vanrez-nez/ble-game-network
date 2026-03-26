local palette = require("ble_ui.palette")
local panel = require("ble_ui.panel")

local M = {}

function M.draw(width, metrics, title, fonts)
  panel.draw(0, 0, width, metrics.topbar_h, 0, palette.panel)
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.title)
  local title_y = math.floor((metrics.topbar_h - fonts.title:getHeight()) * 0.5)
  love.graphics.print(title, metrics.margin, title_y)
end

return M
