local M = {}

function M.clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

function M.safe_area()
  if love.window and love.window.getSafeArea then
    local x, y, w, h = love.window.getSafeArea()
    if x and y and w and h then
      return x, y, w, h
    end
  end

  local width, height = love.graphics.getDimensions()
  return 0, 0, width, height
end

function M.layout_metrics(width, height)
  local margin = M.clamp(math.floor(width * 0.04), 14, 24)
  local gap = M.clamp(math.floor(width * 0.024), 10, 18)
  local topbar_h = M.clamp(math.floor(height * 0.095), 72, 88)
  return {
    margin = margin,
    gap = gap,
    radius = 18,
    topbar_h = topbar_h,
    button_h = M.clamp(math.floor(height * 0.06), 42, 50),
  }
end

return M
