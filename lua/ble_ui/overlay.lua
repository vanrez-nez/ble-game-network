local palette = require("ble_ui.palette")
local buttons = require("ble_ui.buttons")

local Overlay = {}
Overlay.__index = Overlay

function Overlay.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Overlay)
  self.title = opts.title or "Overlay"
  self._open = false
  self.content_fn = opts.content_fn
  return self
end

function Overlay:is_open()
  return self._open
end

function Overlay:open()
  self._open = true
end

function Overlay:close()
  self._open = false
end

function Overlay:toggle()
  self._open = not self._open
end

function Overlay:draw(width, height, fonts, content_fn_override)
  if not self._open then return end

  local fn = content_fn_override or self.content_fn

  love.graphics.setColor(0.02, 0.03, 0.06, 0.94)
  love.graphics.rectangle("fill", 0, 0, width, height)

  local margin = 16
  love.graphics.setColor(palette.text)
  love.graphics.setFont(fonts.section or fonts.body)
  love.graphics.print(self.title, margin, margin + 6)

  local close_w = 64
  local close_h = 28
  buttons.register(width - margin - close_w, margin + 2, close_w, close_h, "Close", function()
    self._open = false
  end, "danger")

  local content_y = margin + 40
  local content_h = height - content_y - margin

  if fn then
    fn(margin, content_y, width - margin * 2, content_h, fonts)
  end
end

local M = {}
function M.new(opts)
  return Overlay.new(opts)
end

return M
