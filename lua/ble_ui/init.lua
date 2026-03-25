local palette = require("ble_ui.palette")
local util = require("ble_ui.util")
local draw = require("ble_ui.draw")
local lobby = require("ble_ui.lobby")
local diagnostics = require("ble_ui.diagnostics")

local M = {
  palette = palette,
  util = util,
  draw = draw,
  lobby = lobby,
  diagnostics = diagnostics,
  layout_metrics = util.layout_metrics,
  clamp = util.clamp,
  safe_area = util.safe_area,
}

function M.draw_frame(opts)
  local buttons = opts.buttons
  local fonts = opts.fonts
  local width = opts.width
  local height = opts.height
  local metrics = opts.metrics
  local app = opts.app
  local network = opts.network

  diagnostics.clear_view()

  if diagnostics.is_open() then
    diagnostics.draw(width, height, metrics, buttons, fonts, network, app)
  else
    draw.topbar(width, metrics, app.title, fonts)

    if app.in_session then
      opts.draw_session()
    else
      lobby.draw(width, height, metrics, {
        buttons = buttons,
        fonts = fonts,
        app = app,
        network = network,
        description = opts.lobby_description,
        start_host = opts.start_host,
        start_scan = opts.start_scan,
        transport = opts.transport,
      })
    end

    local log_btn_h = 28
    local log_btn_y = math.floor((metrics.topbar_h - log_btn_h) * 0.5)
    draw.register_button(buttons, width - 8 - 64, log_btn_y, 64, log_btn_h, "Logs", function()
      diagnostics.open()
    end, "ghost")
  end

  for i = 1, #buttons do
    draw.button(buttons[i], fonts)
  end
end

return M
