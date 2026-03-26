local palette = require("ble_ui.palette")

local M = {}

local alerts = {}
local DURATION = 3.0
local FADE_TIME = 0.5
local MAX_VISIBLE = 4

function M.push(text, color)
  if #alerts >= MAX_VISIBLE then
    table.remove(alerts, 1)
  end
  alerts[#alerts + 1] = {
    text = tostring(text or ""),
    time = love.timer.getTime(),
    color = color or palette.text,
  }
end

function M.update()
  local now = love.timer.getTime()
  local i = 1
  while i <= #alerts do
    if now - alerts[i].time >= DURATION then
      table.remove(alerts, i)
    else
      i = i + 1
    end
  end
end

function M.draw(width, metrics, fonts)
  if #alerts == 0 then return end

  local now = love.timer.getTime()
  local font = fonts.body
  local margin = metrics.margin
  local banner_w = width - margin * 2
  local banner_h = font:getHeight() + 16
  local gap = 4
  local start_y = metrics.topbar_h + 4

  love.graphics.setFont(font)

  for i = 1, #alerts do
    local a = alerts[i]
    local age = now - a.time
    local remaining = DURATION - age
    local alpha = remaining < FADE_TIME and (remaining / FADE_TIME) or 1.0
    alpha = math.max(0, math.min(1, alpha))

    local x = margin
    local y = start_y + (i - 1) * (banner_h + gap)

    -- Background
    love.graphics.setColor(0.08, 0.10, 0.14, 0.92 * alpha)
    love.graphics.rectangle("fill", x, y, banner_w, banner_h, 10, 10)

    -- Accent bar on left
    local c = a.color
    love.graphics.setColor(c[1], c[2], c[3], 0.8 * alpha)
    love.graphics.rectangle("fill", x, y, 4, banner_h, 10, 0)

    -- Text
    love.graphics.setColor(c[1], c[2], c[3], alpha)
    local text_y = y + math.floor((banner_h - font:getHeight()) * 0.5)
    love.graphics.printf(a.text, x + 14, text_y, banner_w - 28, "left")
  end
end

function M.clear()
  alerts = {}
end

return M
