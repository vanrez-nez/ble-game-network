local palette = require("ble_ui.palette")
local util = require("ble_ui.util")
local buttons = require("ble_ui.buttons")
local panel = require("ble_ui.panel")
local topbar = require("ble_ui.topbar")
local overlay = require("ble_ui.overlay")
local draw = require("ble_ui.draw")
local lobby = require("ble_ui.lobby")

local M = {
  palette = palette,
  util = util,
  buttons = buttons,
  panel = panel,
  topbar = topbar,
  overlay = overlay,
  draw = draw,
  lobby = lobby,
  layout_metrics = util.layout_metrics,
  clamp = util.clamp,
  safe_area = util.safe_area,
}

function M.draw_frame(opts)
  local fonts = opts.fonts
  local width = opts.width
  local height = opts.height
  local metrics = opts.metrics
  local app = opts.app
  local network = opts.network
  local overlays = opts.overlays or {}

  buttons.reset()

  local active_overlay = nil
  for i = 1, #overlays do
    if overlays[i]:is_open() then
      active_overlay = overlays[i]
      break
    end
  end

  if active_overlay then
    active_overlay:draw(width, height, fonts)
  else
    topbar.draw(width, metrics, app.title, fonts)

    if app.in_session then
      opts.draw_session()
    else
      lobby.draw(width, height, metrics, {
        fonts = fonts,
        app = app,
        network = network,
        description = opts.lobby_description,
        start_host = opts.start_host,
        start_scan = opts.start_scan,
        transport = opts.transport,
      })
    end

    if opts.extra_buttons then
      opts.extra_buttons()
    end
  end

  buttons.render(fonts)
end

return M
