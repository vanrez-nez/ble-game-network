local palette = require("ble_ui.palette")

local M = {}

function M.draw(x, y, w, h, radius, fill)
  love.graphics.setColor(fill or palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, radius, radius)
  love.graphics.setColor(palette.stroke)
  love.graphics.rectangle("line", x, y, w, h, radius, radius)
end

return M
