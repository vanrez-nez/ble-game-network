--
-- Button manager for ble_ui
-- Event model from freakmangd/Simple-Button v1.0
--

local palette = require("ble_ui.palette")

local ButtonManager = {}
ButtonManager.Buttons = {}

local lg = love.graphics

---@class Button
local Button = {
  update = function() end,
  draw = function(self)
    if not self.interactable then
      self.currentColor = self.disabledColor
    end

    local r, g, b, a = lg.getColor()

    lg.setColor(self.currentColor)
    lg.rectangle(self.fillType, self.x, self.y, self.width, self.height, 14, 14)

    if self.strokeColor then
      lg.setColor(self.strokeColor)
      lg.rectangle("line", self.x, self.y, self.width, self.height, 14, 14)
    end

    if self.label and self.label ~= "" and self.font then
      if not self.interactable then
        lg.setColor(self.textColor[1], self.textColor[2], self.textColor[3], 0.35)
      else
        lg.setColor(self.textColor)
      end
      lg.setFont(self.font)
      local textY = self.y + math.floor((self.height / 2) - (self.font:getHeight() / 2))
      lg.printf(self.label, self.x + 10, textY, self.width - 20, "center")
    end

    lg.setColor(r, g, b, a)
  end,
  onClick = function() end,
  onToggleOn = function() end,
  onToggleOff = function() end,
  onRelease = function() end,
}
Button.__index = Button

ButtonManager.default = {
  label = "",
  x = 0,
  y = 0,
  width = 50,
  height = 50,
  toggle = false,
  fillType = "fill",
  color = palette.panel_alt,
  textColor = palette.text,
  pressedColor = {0.24, 0.29, 0.36},
  toggledColor = {0.20, 0.25, 0.31},
  disabledColor = {0.15, 0.17, 0.20, 0.6},
  strokeColor = {0, 0, 0, 0.18},
  visible = true,
}

-- Style presets applied on top of defaults
local stylePresets = {
  accent = {
    color = palette.accent,
    pressedColor = palette.accent_soft,
    textColor = {0.09, 0.08, 0.07},
  },
  danger = {
    color = palette.danger,
    pressedColor = {0.96, 0.49, 0.46},
    textColor = {0.09, 0.08, 0.07},
  },
  ghost = {
    color = {0.11, 0.14, 0.18, 0.92},
    pressedColor = {0.22, 0.27, 0.34, 0.96},
    textColor = palette.dim,
    strokeColor = palette.stroke,
  },
  invisible = {
    visible = false,
  },
}

--- Create a new button and add it to ButtonManager.Buttons
function ButtonManager.new(label, x, y, width, height, onClick, style, opts)
  local newButton = setmetatable({}, Button)
  opts = opts or {}
  local preset = stylePresets[style or "default"] or {}

  newButton.label = label or ButtonManager.default.label
  newButton.x = x or ButtonManager.default.x
  newButton.y = y or ButtonManager.default.y
  newButton.width = width or ButtonManager.default.width
  newButton.height = height or ButtonManager.default.height

  newButton.fillType = ButtonManager.default.fillType
  newButton.color = preset.color or ButtonManager.default.color
  newButton.textColor = preset.textColor or ButtonManager.default.textColor
  newButton.pressedColor = preset.pressedColor or ButtonManager.default.pressedColor
  newButton.toggledColor = preset.toggledColor or ButtonManager.default.toggledColor
  newButton.disabledColor = preset.disabledColor or ButtonManager.default.disabledColor
  newButton.strokeColor = preset.strokeColor or ButtonManager.default.strokeColor
  newButton.currentColor = newButton.color
  if preset.visible ~= nil then
    newButton.visible = preset.visible
  else
    newButton.visible = ButtonManager.default.visible
  end

  newButton.toggle = opts.toggle or false
  if newButton.toggle then
    newButton.value = false
  end

  newButton.enabled = true
  newButton.interactable = opts.interactable ~= false
  newButton.font = opts.font or nil

  newButton.update = ButtonManager.default.update or Button.update
  newButton.draw = Button.draw
  newButton.onClick = onClick or Button.onClick
  newButton.onRelease = opts.onRelease or Button.onRelease
  newButton.onToggleOn = opts.onToggleOn or Button.onToggleOn
  newButton.onToggleOff = opts.onToggleOff or Button.onToggleOff

  table.insert(ButtonManager.Buttons, newButton)
  return newButton
end

--- Backward-compat alias: register(x, y, w, h, label, action, style, opts)
function ButtonManager.register(x, y, w, h, label, action, style, opts)
  return ButtonManager.new(label, x, y, w, h, action, style, opts)
end

--- Clear all buttons
function ButtonManager.reset()
  ButtonManager.Buttons = {}
end

--- Update all buttons
function ButtonManager.update(dt)
  for _, v in ipairs(ButtonManager.Buttons) do
    if v.enabled then
      v:update(dt)
    end
  end
end

--- Invoke mousepressed for all buttons. Returns true if any button was clicked.
function ButtonManager.mousepressed(x, y, button)
  button = button or 1
  local anyClicked = false
  if button == 1 then
    for _, v in ipairs(ButtonManager.Buttons) do
      if v.enabled and v.interactable then
        if x > v.x and x < v.x + v.width and y > v.y and y < v.y + v.height then
          if v.toggle then
            v.value = not v.value

            if v.value == true then
              v:onClick()
              v:onToggleOn()
            else
              v:onClick()
              v:onToggleOff()
            end
          else
            v:onClick()
          end

          v.currentColor = v.pressedColor
          anyClicked = true
        end
      end
    end
  end
  return anyClicked
end

--- Invoke mousereleased for all buttons. Returns true if any button was changed.
function ButtonManager.mousereleased(x, y, button)
  button = button or 1
  local anyChanged = false
  if button == 1 then
    for _, v in ipairs(ButtonManager.Buttons) do
      if v.enabled then
        v:onRelease()

        if v.toggle then
          if v.value == true then
            v.currentColor = v.toggledColor
          else
            v.currentColor = v.color
          end
        else
          v.currentColor = v.color
        end
        anyChanged = true
      end
    end
  end
  return anyChanged
end

--- Backward compat alias
function ButtonManager.pressed(x, y)
  return ButtonManager.mousepressed(x, y, 1)
end

--- Draw all or one button
function ButtonManager.draw(b)
  if b then
    if b.enabled and b.visible ~= false then
      b:draw()
    end
  else
    for _, v in ipairs(ButtonManager.Buttons) do
      ButtonManager.draw(v)
    end
  end
end

--- Alias
function ButtonManager.render(fonts)
  -- Set font on all buttons that don't have one
  if fonts and fonts.body then
    for _, v in ipairs(ButtonManager.Buttons) do
      if not v.font then
        v.font = fonts.body
      end
    end
  end
  ButtonManager.draw()
end

function ButtonManager.count()
  return #ButtonManager.Buttons
end

return ButtonManager
